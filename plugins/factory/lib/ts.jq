# ts2s: an ISO 8601 timestamp (Z or a numeric offset, optional fraction) as epoch seconds.
def ts2s:
  capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$") as $c
  | ($c.d + "Z" | fromdateiso8601) as $base
  | if $c.z == "Z" then $base
    else (($c.z[1:3] | tonumber) * 3600 + ($c.z[4:6] | tonumber) * 60) as $o
      | if $c.z[0:1] == "+" then $base - $o else $base + $o end end;
