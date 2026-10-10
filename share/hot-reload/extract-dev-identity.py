#!/usr/bin/python3
"""Copy xtool's development signing identity out for hot reload.

    extract-dev-identity.py

Hot reload signs each swap library with the same Apple Development
certificate xtool signs your apps with. xtool keeps that certificate and its
private key inside its own data folder (~/.config/xtool/data/<issuer id>, a
binary plist: {privateKey: {data: PEM}, certificate: {data: DER}}). This copies
them to ~/.config/omarchy-apple-dev/development/ as key.pem and cert.der, the
place omarchy-apple-dev's tools/sign-dev.sh also uses.

Run it yourself (it handles your private key): nothing is printed except the
certificate's name and expiry date. The folder is owner-only (700) and the
files 600. It reuses xtool's existing certificate: nothing new is created in
your Apple account. Run it again after xtool renews its certificate.
"""
import glob, os, plistlib, subprocess, sys

base = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "xtool", "data")
dst = os.path.expanduser("~/.config/omarchy-apple-dev/development")


def unwrap(v):
    if isinstance(v, dict):
        v = v.get("data")
    return v.encode() if isinstance(v, str) else v


found = None
for path in glob.glob(os.path.join(base, "*")):
    try:
        d = plistlib.load(open(path, "rb"))
    except Exception:
        continue
    if isinstance(d, dict) and "privateKey" in d and "certificate" in d:
        key, cert = unwrap(d["privateKey"]), unwrap(d["certificate"])
        if key and key.startswith(b"-----BEGIN") and cert:
            found = (key, cert)
            break
if not found:
    sys.exit(f"No signing identity found in {base}. Sign in first (`xtool auth`) and install an app once (ios-run).")

os.makedirs(dst, mode=0o700, exist_ok=True)
os.chmod(dst, 0o700)
os.umask(0o077)
open(os.path.join(dst, "key.pem"), "wb").write(found[0])
open(os.path.join(dst, "cert.der"), "wb").write(found[1])
subprocess.run(["openssl", "x509", "-inform", "der", "-in", os.path.join(dst, "cert.der"),
                "-noout", "-subject", "-enddate"])
print("wrote", dst, "(key.pem, cert.der, mode 600)")
