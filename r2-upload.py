#!/usr/bin/env python3
# =============================================================================
# AuroraOS — multipart-upload the ISO to Cloudflare R2 via the S3 API
# =============================================================================
# R2 speaks S3. boto3 handles multipart upload automatically for large files,
# which is exactly what we need (the ISO is ~2.4GB; wrangler caps at 300MB).
# =============================================================================
import os, sys, hashlib, boto3
from botocore.client import Config


def _load_dotenv():
    """Load a gitignored .env next to this script (does not override real env)."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if not os.path.isfile(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


_load_dotenv()

# -----------------------------------------------------------------------------
# Credentials come from the environment — NEVER hardcode them in source.
#   export R2_ACCESS_KEY_ID=...      (or AWS_ACCESS_KEY_ID)
#   export R2_SECRET_ACCESS_KEY=...  (or AWS_SECRET_ACCESS_KEY)
#   export R2_ACCOUNT_ID=...
#
# NOTE: an earlier version of this file had live R2 keys committed in plaintext.
# Those are permanently compromised — rotate/revoke that R2 API token in the
# Cloudflare dashboard (R2 > Manage API tokens) and issue a new one scoped to
# write-only on the 'auroraos-iso' bucket.
# -----------------------------------------------------------------------------
AKID = os.environ.get("R2_ACCESS_KEY_ID") or os.environ.get("AWS_ACCESS_KEY_ID")
SECRET = os.environ.get("R2_SECRET_ACCESS_KEY") or os.environ.get("AWS_SECRET_ACCESS_KEY")
ACCOUNT = os.environ.get("R2_ACCOUNT_ID", "19b9b5fbb35ca9dbc69b99d8531f04de")
BUCKET = os.environ.get("R2_BUCKET", "auroraos-iso")
# R2 object key is the FIXED internal name the download Worker reads — it stays
# 0.1 forever; the user-facing filename + version come from the 'version'
# metadata below, NOT from this key. The LOCAL path, however, must track what
# build.sh actually produces (auroraos-<VERSION>-amd64.iso).
KEY = os.environ.get("R2_KEY", "auroraos-0.1-amd64.iso")
LOCAL = os.environ.get(
    "R2_LOCAL_ISO",
    "/mnt/c/Users/User/Downloads/Z AI Creations/Operating System/build-output/auroraos-0.57-amd64.iso",
)

if not AKID or not SECRET:
    sys.exit(
        "ERROR: set R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY in the environment.\n"
        "       (The previously hardcoded keys were leaked and must be rotated.)"
    )

endpoint = f"https://{ACCOUNT}.r2.cloudflarestorage.com"

s3 = boto3.client(
    "s3",
    endpoint_url=endpoint,
    aws_access_key_id=AKID,
    aws_secret_access_key=SECRET,
    region_name="auto",
    config=Config(signature_version="s3v4", retries={"max_attempts": 10}),
)

# Auth check: try listing objects IN the bucket (token may be bucket-scoped,
# in which case account-wide ListBuckets is denied but bucket ops work).
try:
    r = s3.list_objects_v2(Bucket=BUCKET, MaxKeys=1)
    print(f"[r2] bucket '{BUCKET}' accessible. existing objects: {r.get('KeyCount', 0)}")
except Exception as e:
    print(f"[r2] bucket access check FAILED: {e}")
    print("[r2] (continuing anyway — will try the upload directly)")

size = os.path.getsize(LOCAL)
print(f"[r2] uploading {LOCAL}")
print(f"[r2] size: {size:,} bytes ({size/1024/1024/1024:.2f} GiB)")
print(f"[r2] target: s3://{BUCKET}/{KEY}")

# Compute SHA256 for verification + set as metadata
print("[r2] computing SHA256 (this takes a moment)...")
sha = hashlib.sha256()
with open(LOCAL, "rb") as f:
    for chunk in iter(lambda: f.read(8 * 1024 * 1024), b""):
        sha.update(chunk)
digest = sha.hexdigest()
print(f"[r2] SHA256: {digest}")

# Multipart upload with progress
from boto3.s3.transfer import TransferConfig
cfg = TransferConfig(multipart_threshold=200 * 1024 * 1024,
                     multipart_chunksize=200 * 1024 * 1024,
                     max_concurrency=8)

import threading, time
done = threading.Event()
def report():
    while not done.is_set():
        try:
            head = s3.head_object(Bucket=BUCKET, Key=KEY)
        except Exception:
            head = {"ContentLength": 0}
        uploaded = head.get("ContentLength", 0)
        pct = (uploaded / size * 100) if size else 0
        print(f"  [progress] note: head shows current object size {uploaded:,} — multipart upload in progress")
        time.sleep(15)
t = threading.Thread(target=report, daemon=True)
t.start()

print("[r2] starting multipart upload...")
try:
    s3.upload_file(
        LOCAL, BUCKET, KEY,
        ExtraArgs={
            "ContentType": "application/octet-stream",
            "Metadata": {"sha256": digest, "version": "0.57"},
        },
        Config=cfg,
    )
    done.set()
    print("[r2] upload complete!")
except Exception as e:
    done.set()
    print(f"[r2] upload FAILED: {e}")
    sys.exit(1)

# Verify
print("[r2] verifying uploaded object...")
head = s3.head_object(Bucket=BUCKET, Key=KEY)
print(f"[r2] uploaded size: {head['ContentLength']:,} bytes")
print(f"[r2] metadata: {head.get('Metadata', {})}")
print(f"[r2] DONE.")
