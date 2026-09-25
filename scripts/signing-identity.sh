# Sourced by package-app.sh and make-dmg.sh.
#
# signing_identity NAME prints the SHA-1 of the valid code-signing identity called NAME, for codesign to
# use instead of the name. Certificates keep their name when they are renewed or re-issued — joining the
# paid developer program issued a second "Apple Development: …" identical in name to the first — and
# codesign refuses a name that matches two, which stopped every build (2026-09-24). With several, it
# picks the one that expires last. Either keeps the Calendar permission: the app's designated requirement
# names the certificate, not a particular one. Prints nothing when there is no such identity.
signing_identity() {
  local name="$1" hash best="" best_end=0 end pem
  while read -r hash; do
    [[ -n "$hash" ]] || continue
    pem="$(security find-certificate -a -Z -p -c "$name" 2>/dev/null \
      | awk -v h="$hash" '/^SHA-1 hash:/ {take = ($3 == h)} take && /BEGIN CERTIFICATE/ {on=1} on {print} on && /END CERTIFICATE/ {on=0; take=0}')"
    end="$(printf '%s\n' "$pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
    end="$(date -j -f "%b %e %T %Y %Z" "$end" +%s 2>/dev/null || echo 0)"
    if [[ -z "$best" || "$end" -gt "$best_end" ]]; then
      best="$hash"
      best_end="$end"
    fi
  done < <(security find-identity -v -p codesigning 2>/dev/null | awk -v n="\"$name\"" 'index($0, n) {print $2}')
  printf '%s' "$best"
}
