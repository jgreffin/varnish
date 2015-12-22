changequote([[,]])dnl
define(VARNISH_NAME, [[default]])dnl
define(VARNISH_CANONICAL_HOST, )dnl
define(VARNISH_BACKEND_HOST, [[localhost]])dnl
define(VARNISH_BACKEND_PORT, [[80]])dnl
define(VARNISH_BACKEND_CONNECT_TIMEOUT, [[20s]])dnl
define(VARNISH_BACKEND_FIRST_BYTE_TIMEOUT, [[600s]])dnl
define(VARNISH_BACKEND_BETWEEN_BYTES_TIMEOUT, [[20s]])dnl
define(VARNISH_PROBE_REQUEST, GET /wp-login/ HTTP/1.1)dnl
define(VARNISH_PROBE_HOST, localhost)dnl
define(VARNISH_PROBE_WINDOW, 5)dnl
define(VARNISH_PROBE_THRESHOLD, 3)dnl
define(VARNISH_PROBE_INTERVAL, 5s)dnl
define(VARNISH_PROBE_TIMEOUT, 15000ms)dnl
define(VARNISH_GRACE_HEALTHY, 600s)dnl
define(VARNISH_GRACE_UNHEALTHY, 48h)dnl
define(VARNISH_TTL_CONTENT, 300s)dnl
define(VARNISH_TTL_ASSETS, 1d)dnl
vcl 4.0;

import std;
import directors;

# Inspired heavily by https://github.com/mattiasgeniar/varnish-4.0-configuration-templates/blob/master/default.vcl
#     Based on: https://github.com/mattiasgeniar/varnish-4.0-configuration-templates/blob/master/default.vcl

# This is a basic VCL configuration file for varnish.  See the vcl(7)
# man page for details on VCL syntax and semantics.

# default health check
probe healthcheck { 
  #.url = "/robots.txt"; 
  .timeout = VARNISH_PROBE_TIMEOUT; 
  .interval = VARNISH_PROBE_INTERVAL; 
  .window = VARNISH_PROBE_WINDOW; 
  .threshold = VARNISH_PROBE_THRESHOLD; 
  .request =
          "VARNISH_PROBE_REQUEST"
          "Host: VARNISH_PROBE_HOST"
          "Connection: close";
}

# 
# Default backend definition.  Set this to point to your content
# server.
# 

{{range ls "/"}}
{{  $path := printf "/%s" .}}
{{  if exists $path}}
{{ $resource := split (getv $path) ":" }}
backend backend_{{.}} {
  .host = "{{index $resource 0}}";
  .port = "{{index $resource 1}}";
  .connect_timeout = VARNISH_BACKEND_CONNECT_TIMEOUT;
  .first_byte_timeout = VARNISH_BACKEND_FIRST_BYTE_TIMEOUT;
  .between_bytes_timeout = VARNISH_BACKEND_BETWEEN_BYTES_TIMEOUT;
  .probe = healthcheck;
}
{{  else}}
{{    range ls $path}}
{{      $subpath := printf "%s/%s" $path .}}
{{      if exists $subpath}}
{{        $resource := split (getv $subpath) ":" }}
backend backend_{{.}} {
  .host = "{{index $resource 0}}";
  .port = "{{index $resource 1}}";
  .connect_timeout = VARNISH_BACKEND_CONNECT_TIMEOUT;
  .first_byte_timeout = VARNISH_BACKEND_FIRST_BYTE_TIMEOUT;
  .between_bytes_timeout = VARNISH_BACKEND_BETWEEN_BYTES_TIMEOUT;
  .probe = healthcheck;
}
{{      end}}
{{    end}}
{{  end}}
{{end}}


sub vcl_init {
  new lb = directors.round_robin();
{{range ls "/"}}
{{  $path := printf "/%s" .}}
{{  if exists $path}}
  lb.add_backend(backend_{{.}});
{{  else}}
{{    range ls $path}}
{{      $subpath := printf "%s/%s" $path .}}
{{      if exists $subpath}}
{{        $resource := split (getv $subpath) ":" }}
  lb.add_backend(backend_{{.}});
{{      end}}
{{    end}}
{{  end}}
{{end}}

	return (ok);

}


# 
# Below is a commented-out copy of the default VCL logic.  If you
# redefine any of these subroutines, the built-in logic will be
# appended to your code.
sub vcl_recv {

  set req.backend_hint = lb.backend();
  set req.http.X-Grace = "none";

  if (req.restarts == 0) {
    if (req.http.x-forwarded-for) {
      set req.http.X-Forwarded-For = req.http.X-Forwarded-For + ", " + client.ip;
    } else {
      set req.http.X-Forwarded-For = client.ip;
    }
  }

  if(req.url ~ "^/wp-.*\.php" || req.url ~ "^/xmlrpc\.php$") {
    if(!req.http.User-Agent || req.http.User-Agent ~ "^$") {
      return (synth(403, "Invalid request"));
    }
  }

  # Normalize the header, remove the port (in case you're testing this on various TCP ports); 
  # We store the original Host header in X-Original-Host, if the backend needs it for processing.
  set req.http.X-Original-Host = regsub(req.http.Host, ":[0-9]+", ""); 
  set req.http.Host = ifelse(VARNISH_CANONICAL_HOST, [[]], regsub(req.http.Host, ":[0-9]+", ""), "[[VARNISH_CANONICAL_HOST]]");

  # Normalize the query arguments
  set req.url = std.querysort(req.url);

  # Implementing websocket support (https://www.varnish-cache.org/docs/4.0/users-guide/vcl-example-websockets.html)
  if (req.http.Upgrade ~ "(?i)websocket") {
    return (pipe);
  }

  # Only cache GET or HEAD requests. This makes sure the POST requests are always passed.
  if (req.method != "GET" && req.method != "HEAD") {
    return (pass);
  }

  if (req.http.Authorization) {
    # Not cacheable by default
    return (pass);
  }

  if (req.url ~ "\?(utm_(campaign|medium|source|term)|adParams|client|cx|eid|fbid|feed|ref(id|src)?|v(er|iew))=") {
    set req.url = regsub(req.url, "\?.*$", "");
  }

  if (req.url ~ "wp-(login|admin)" || req.url ~ "preview=true" || req.url ~ "xmlrpc.php" ) {
    return(pass);
  }

  if (req.url ~ "apache/status" ) {
    return(pass);
  }


  # Some generic URL manipulation, useful for all templates that follow
  # First remove the Google Analytics added parameters, useless for our backend
  if (req.url ~ "(\?|&)(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=") {
    set req.url = regsuball(req.url, "&(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "");
    set req.url = regsuball(req.url, "\?(utm_source|utm_medium|utm_campaign|utm_content|gclid|cx|ie|cof|siteurl)=([A-z0-9_\-\.%25]+)", "?");
    set req.url = regsub(req.url, "\?&", "?");
    set req.url = regsub(req.url, "\?$", "");
  }

  # Strip hash, server doesn't need it.
  if (req.url ~ "\#") {
    set req.url = regsub(req.url, "\#.*$", "");
  }

  # Strip a trailing ? if it exists
  if (req.url ~ "\?$") {
    set req.url = regsub(req.url, "\?$", "");
  }

  # Remove any Google Analytics based cookies
  set req.http.Cookie = regsuball(req.http.Cookie, "__utm.=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "_ga=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "_gat=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "utmctr=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "utmcmd.=[^;]+(; )?", "");
  set req.http.Cookie = regsuball(req.http.Cookie, "utmccn.=[^;]+(; )?", "");

  # Remove DoubleClick offensive cookies
  set req.http.Cookie = regsuball(req.http.Cookie, "__gads=[^;]+(; )?", "");

  # Remove the Quant Capital cookies (added by some plugin, all __qca)
  set req.http.Cookie = regsuball(req.http.Cookie, "__qc.=[^;]+(; )?", "");

  # Remove the AddThis cookies
  set req.http.Cookie = regsuball(req.http.Cookie, "__atuv.=[^;]+(; )?", "");

  # Remove a ";" prefix in the cookie if present
  set req.http.Cookie = regsuball(req.http.Cookie, "^;\s*", "");

  # Are there cookies left with only spaces or that are empty?
  if (req.http.cookie ~ "^\s*$") {
    unset req.http.cookie;
  }

  # Authenticated users can bypass the cache
  if (req.http.cookie) {
    if (req.http.cookie ~ "(wordpress_|wp-settings-)") {
      if (req.http.Cache-Control ~ "no-cache" && req.restarts == 0) {
        return (purge);
      } else {
        return(pass);
      }
    } else {
      unset req.http.cookie;
    }
  }

  # Remove all cookies for static files
  # A valid discussion could be held on this line: do you really need to cache static files that don't cause load? Only if you have memory left.
  # Sure, there's disk I/O, but chances are your OS will already have these files in their buffers (thus memory).
  # Before you blindly enable this, have a read here: https://ma.ttias.be/stop-caching-static-files/
  if (req.url ~ "^[^?]*\.(bmp|bz2|css|doc|eot|flv|gif|gz|ico|jpeg|jpg|js|less|pdf|png|rtf|swf|txt|woff|xml)(\?.*)?$") {
    unset req.http.Cookie;
    return (hash);
  }


  if (req.method != "GET" &&
    req.method != "HEAD" &&
    req.method != "PUT" &&
    req.method != "POST" &&
    req.method != "TRACE" &&
    req.method != "OPTIONS" &&
    req.method != "DELETE") {
      /* Non-RFC2616 or CONNECT which is weird. */
      return (pipe);
  }
  if (req.method != "GET" && req.method != "HEAD") {
      /* We only deal with GET and HEAD by default */
      return (pass);
  }
  if (req.http.Authorization || req.http.Cookie) {
      /* Not cacheable by default */
      return (pass);
  }

  return (hash);
}

sub vcl_purge {
  if (req.method != "PURGE") {
    # restart request
    set req.http.X-Purge = "Yes";
    return(restart);
  }
}

sub vcl_pipe {
  # Note that only the first request to the backend will have
  # X-Forwarded-For set.  If you use X-Forwarded-For and want to
  # have it set for all requests, make sure to have:
  # set bereq.http.connection = "close";
  # here.  It is not set by default as it might break some broken web
  # applications, like IIS with NTLM authentication.

  # Implementing websocket support (https://www.varnish-cache.org/docs/4.0/users-guide/vcl-example-websockets.html)
  if (req.http.upgrade) {
    set bereq.http.upgrade = req.http.upgrade;
  }

  return (pipe);
}

sub vcl_pass {
  return (fetch);
}

sub vcl_hash {
  hash_data(req.url);
  if (req.http.host) {
      hash_data(req.http.host);
  } else {
      hash_data(server.ip);
  }
  return (lookup);
}

sub vcl_hit {

  if (obj.ttl >= 0s) {
    # normal hit
    return (deliver);
  }

  # We have no fresh fish. Lets look at the stale ones.
  if (std.healthy(req.backend_hint)) {
    # Backend is healthy. Limit age to 10s.
    if (obj.ttl + VARNISH_GRACE_HEALTHY > 0s) {
      set req.http.X-Grace = "normal(limited)";
      return (deliver);
    } else {
      # No candidate for grace. Fetch a fresh object.
      return(fetch);
   }
  } else {
    # backend is sick - use full grace
    if (obj.ttl + obj.grace > 0s) {
      set req.http.X-Grace = "full";
      return (deliver);
    } else {
     # no graced object.
     return (fetch);
    }
  }

  return (deliver);
}

sub vcl_miss {
  return (fetch);
}


sub vcl_backend_response {

  # This code snippet tells varnish to keep objects VARNISH_GRACE_UNHEALTHY hour in cache past their expiry time
  set beresp.grace = VARNISH_GRACE_UNHEALTHY;

  if (bereq.method == "GET" || bereq.method == "HEAD") {
    # It's only possible to cache these types of requests
    set beresp.ttl = VARNISH_GRACE_HEALTHY;

    if (bereq.url !~ "(wp-(login|admin)|login)") {
      unset beresp.http.Set-Cookie;
      unset beresp.http.Vary;
      unset beresp.http.Expires;
      unset beresp.http.Cache-Control;
      unset beresp.http.Last-Modified;
      unset beresp.http.Pragma;

      set beresp.ttl = VARNISH_TTL_CONTENT;

    }
  } else {
    set beresp.ttl = 0s;
    return (deliver);
  }

  # Do not cache rogue empty responses
  if(beresp.http.Content-Length == "0" && beresp.status < 300 ) {
    return (abandon);
  }


  # Enable cache for all static files
  # The same argument as the static caches from above: monitor your cache size, if you get data nuked out of it, consider giving up the static file cache.
  # Before you blindly enable this, have a read here: https://ma.ttias.be/stop-caching-static-files/
  if (bereq.url ~ "^[^?]*\.(bmp|bz2|css|doc|eot|flv|gif|gz|ico|jpeg|jpg|js|less|mp[34]|pdf|png|rar|rtf|swf|tar|tgz|txt|wav|woff|xml|zip)(\?.*)?$") {
    set beresp.ttl = VARNISH_TTL_ASSETS;
    unset beresp.http.set-cookie;
  }

  # Cache errors for a short time, otherwise they can overwhelm the origin
  if (beresp.ttl > 0s && beresp.status > 400) { 
    set beresp.ttl = 30s; 
  }

  if (beresp.ttl <= 0s ||
      beresp.http.Set-Cookie ||
      beresp.http.Surrogate-control ~ "no-store" ||
      (!beresp.http.Surrogate-Control &&
        beresp.http.Cache-Control ~ "no-cache|no-store|private") ||
      beresp.http.Vary == "*") {
        /*
        * Mark as "Hit-For-Pass" for the next 2 minutes
        */
        set beresp.ttl = 120s;
        set beresp.uncacheable = true;
  }
  return (deliver);
}

sub vcl_deliver {
  set resp.http.X-Grace = req.http.X-Grace;
  set resp.http.X-Server = "VARNISH_NAME";
  if (obj.hits > 0) {
    set resp.http.X-Cache = "HIT";
    set resp.http.X-Cache-Hits = obj.hits;
  } else {
    set resp.http.X-Cache = "MISS";
  }

  # Remove some headers: PHP version
  unset resp.http.X-Powered-By;

  # Remove some headers: Apache version & OS
  unset resp.http.Server;
  unset resp.http.X-Drupal-Cache;
  unset resp.http.X-Varnish;
  unset resp.http.Via;
  unset resp.http.Link;
  unset resp.http.X-Generator;

  return (deliver);
}

sub vcl_backend_error {
  set beresp.http.Content-Type = "text/html; charset=utf-8";
  set beresp.http.Retry-After = "5";
  synthetic({"
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
 "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html>
  <head>
    <title>"} + beresp.status + " " + beresp.reason + {"</title>
  </head>
  <body>
    <h1>Error "} + beresp.status + " " + beresp.reason + {"</h1>
    <p>"} + beresp.reason + {"</p>
    <h3>Guru Meditation:</h3>
    <p>XID: "} + bereq.xid + {"</p>
    <hr>
    <p>Varnish cache server</p>
  </body>
</html>
    "});
  return (deliver);
}

sub vcl_fini {
	return (ok);
}
