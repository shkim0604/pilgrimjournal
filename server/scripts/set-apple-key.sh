#!/bin/sh
# Puts an Apple .p8 key into .env.prod without the key ever being printed or pasted. Run it in the
# deploy folder on the Mac mini with the key file on stdin, e.g. from the dev Mac:
#
#   ssh delight 'cd Developments/pilgrim-server && ./scripts/set-apple-key.sh siwa,apns ABCDE12345' \
#     < ~/Downloads/AuthKey_ABCDE12345.p8
#
# Services (comma-separated; one key can serve several when it has them enabled):
#   siwa      Sign in with Apple   → APPLE_SIWA_KEY_ID, APPLE_SIWA_PRIVATE_KEY
#   apns      Apple Push           → APNS_KEY_ID, APNS_PRIVATE_KEY
#   appstore  In-App Purchase key  → APPSTORE_KEY_ID, APPSTORE_PRIVATE_KEY (APPSTORE_ISSUER_ID is
#             set by hand)
# The key is stored on one line with \n between its lines, as .env.prod.example describes.
set -eu

usage() {
  echo "usage: $0 <siwa,apns,appstore> <KEY_ID> < AuthKey_<KEY_ID>.p8" >&2
  exit 64
}
[ $# -eq 2 ] || usage
services=$1
key_id=$2
case $key_id in
  '' | *[!A-Z0-9]*) echo "the key ID is the 10 letters and digits in the file name" >&2; exit 64 ;;
esac
[ -f .env.prod ] || { echo "no .env.prod in $(pwd)" >&2; exit 66; }

pem=$(awk 'NF { printf "%s\\n", $0 }')
case $pem in
  '-----BEGIN PRIVATE KEY-----'*) ;;
  *) echo "stdin is not a .p8 private key" >&2; exit 65 ;;
esac

set_var() {
  grep -q "^$1=" .env.prod || { echo "$1 is missing from .env.prod" >&2; exit 1; }
  NAME=$1 VALUE=$2 perl -pi -e 's/^\Q$ENV{NAME}\E=.*/$ENV{NAME}=$ENV{VALUE}/' .env.prod
  echo "set $1"
}

for service in $(echo "$services" | tr ',' ' '); do
  case $service in
    siwa) set_var APPLE_SIWA_KEY_ID "$key_id"; set_var APPLE_SIWA_PRIVATE_KEY "$pem" ;;
    apns) set_var APNS_KEY_ID "$key_id"; set_var APNS_PRIVATE_KEY "$pem" ;;
    appstore) set_var APPSTORE_KEY_ID "$key_id"; set_var APPSTORE_PRIVATE_KEY "$pem" ;;
    *) echo "unknown service: $service" >&2; usage ;;
  esac
done
chmod 600 .env.prod
echo "done; run make deploy (or make prod on the Mac mini) to apply"
