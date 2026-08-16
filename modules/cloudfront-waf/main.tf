# =============================================================================
# CloudFront distribution
# =============================================================================
# Behaviours, in evaluation order (CloudFront matches ordered_cache_behavior by
# path_pattern in the order declared, then falls through to default):
#
#   /ping*   -> authenticated, GET/HEAD only, no cache, Authorization forwarded
#   /pong*   -> same
#   /health  -> public, GET/HEAD only, no cache, Authorization NOT forwarded
#   /        -> default: public HTML docs page, GET/HEAD only
#
# Every behaviour points at the same single origin -- the ALB. They differ in
# what they forward and what methods they permit, which is the whole point of
# declaring them separately rather than using one catch-all.
# =============================================================================

locals {
  origin_id = "${var.name_prefix}-alb"

  # GET/HEAD only, everywhere. echo-pong has no mutating endpoint: /ping, /pong,
  # /health and / are all reads. Allowing POST/PUT/DELETE at the edge would
  # mean CloudFront forwards methods the origin can only answer with 405,
  # turning the edge into a free amplifier for anyone probing for one.
  # DECISION recorded here rather than left as "your call": the default `/`
  # behaviour is ALSO restricted to GET/HEAD for the same reason.
  read_only_methods = ["GET", "HEAD"]
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  is_ipv6_enabled = true
  price_class     = var.price_class
  aliases         = local.cf_aliases
  comment         = "echo-pong ${var.name_prefix}"
  http_version    = "http2and3"

  # No default_root_object: the origin serves the docs page at / itself. Setting
  # it would make CloudFront rewrite / to /index.html, which the origin 404s.

  web_acl_id = var.web_acl_arn_override != "" ? var.web_acl_arn_override : aws_wafv2_web_acl.cloudfront.arn

  origin {
    domain_name = var.origin_fqdn
    origin_id   = local.origin_id

    custom_origin_config {
      http_port  = 80
      https_port = 443
      # https-only: the CloudFront-to-ALB hop carries the Authorization header
      # and the origin-verify secret. match-viewer would let a viewer
      # downgrade that hop to plaintext by connecting over HTTP.
      origin_protocol_policy = "https-only"
      # TLSv1.2 floor to the origin. The ALB is ours, so there is no legacy
      # client to accommodate.
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 30
      origin_keepalive_timeout = 5
    }

    # The origin verification header. This is the ONLY place the secret value
    # leaves Terraform, and it goes into a resource attribute AWS treats as
    # sensitive. It is never in the comment, the tags, or an output.
    custom_header {
      name  = local.origin_verify_header
      value = random_password.origin_verify.result
    }

    # The app sleeps 10 seconds before its listener opens and has NO SIGTERM
    # handling, so a terminating pod's connections are cut rather than drained.
    # Both are app-side facts this stack cannot fix from the edge. What it can
    # do is retry a connection-level failure at another origin attempt rather
    # than surfacing a 502 to the client.
    connection_attempts = 3
    connection_timeout  = 10
  }

  # ---------------------------------------------------------------------------
  # /ping* -- authenticated
  # ---------------------------------------------------------------------------
  ordered_cache_behavior {
    path_pattern           = "/ping*"
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "https-only"

    allowed_methods = local.read_only_methods
    cached_methods  = local.read_only_methods

    cache_policy_id            = aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = aws_cloudfront_origin_request_policy.authenticated.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    # Off. CloudFront only compresses bodies above ~1000 bytes; a /ping
    # response is a few dozen. Enabling it here would be configuration that
    # never fires, and it would strip the strong ETag if the origin ever set one.
    compress = false
  }

  # ---------------------------------------------------------------------------
  # /pong* -- authenticated
  # ---------------------------------------------------------------------------
  ordered_cache_behavior {
    path_pattern           = "/pong*"
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "https-only"

    allowed_methods = local.read_only_methods
    cached_methods  = local.read_only_methods

    cache_policy_id            = aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = aws_cloudfront_origin_request_policy.authenticated.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    compress = false
  }

  # ---------------------------------------------------------------------------
  # /health -- public
  # ---------------------------------------------------------------------------
  # Exact path, not a prefix: /health is a single endpoint and /healthzzz should
  # fall through to the default behaviour, not inherit the public policy.
  ordered_cache_behavior {
    path_pattern           = "/health"
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "https-only"

    allowed_methods = local.read_only_methods
    cached_methods  = local.read_only_methods

    # Uncached deliberately. A cached /health would report the state of the
    # origin as it was up to the TTL ago, which is worse than useless for the
    # one endpoint whose entire purpose is telling you the current state.
    cache_policy_id            = aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = aws_cloudfront_origin_request_policy.public.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    compress = false
  }

  # ---------------------------------------------------------------------------
  # default (/) -- public HTML docs page
  # ---------------------------------------------------------------------------
  default_cache_behavior {
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = local.read_only_methods
    cached_methods  = local.read_only_methods

    # Caching is OFF by default even here. The docs page is static enough to
    # cache, but caching it means an origin that is completely down still
    # serves a 200 at /, which makes "is the site up?" ambiguous during an
    # incident. Set default_root_object_cache_seconds > 0 to opt in once
    # there is a reason to.
    cache_policy_id = var.default_root_object_cache_seconds > 0 ? aws_cloudfront_cache_policy.docs_page.id : aws_cloudfront_cache_policy.disabled.id

    origin_request_policy_id   = aws_cloudfront_origin_request_policy.public.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    # ON here, and only here. The docs page is HTML of a size where gzip/brotli
    # actually pays for itself.
    compress = true
  }

  viewer_certificate {
    acm_certificate_arn = var.viewer_certificate_arn
    ssl_support_method  = "sni-only"
    # TLSv1.2_2021 is the strictest policy CloudFront offers that is still
    # broadly compatible. It drops TLS 1.0/1.1 and the weaker 1.2 ciphers.
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      # No geo restriction. The client population is not known to be
      # geographically bounded, and a geo block that is wrong is an outage for
      # a legitimate user with no error message that explains it.
      restriction_type = "none"
    }
  }

  # Do not surface the origin's 5xx body to clients, and cache the error page
  # briefly so an origin outage does not become an origin stampede.
  custom_error_response {
    error_code            = 502
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 503
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 504
    error_caching_min_ttl = 10
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-cloudfront" })
}
