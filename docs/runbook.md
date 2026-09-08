# Runbook

Operational procedures for this platform. Each entry is written to be followed under
pressure: the symptom first, then the check, then the fix.

## Backups

### Verify a backup actually ran

```console
kubectl -n apps get cronjob postgres-backup
kubectl -n apps get jobs -l job-name --sort-by=.metadata.creationTimestamp | tail -5
kubectl -n apps logs job/<most-recent-job>
```

A successful run ends with `backup complete: demo-<timestamp>.sql.gz`. The job verifies the
gzip stream and rejects a dump under 1 KB before uploading, because a truncated dump — the
usual result of a pod evicted mid-run — otherwise uploads happily and is discovered only
during a restore.

### List what is stored

```console
kubectl -n apps exec deploy/minio -- \
  mc --no-color ls local/backups/postgres/
```

### Restore

Restoring over a live database is destructive. Take a fresh dump first if the current data
has any value.

```console
# 1. pick a backup
kubectl -n apps exec deploy/minio -- mc ls local/backups/postgres/

# 2. pull it into the postgres pod
kubectl -n apps exec -i postgres-0 -- sh -c 'cat > /tmp/restore.sql.gz' \
  < ./demo-20260908-020000.sql.gz

# 3. stop writers so nothing races the restore
kubectl -n apps scale deploy/demo-api --replicas=0

# 4. restore
kubectl -n apps exec -i postgres-0 -- sh -c \
  'gunzip -c /tmp/restore.sql.gz | psql -U demo -d demo'

# 5. bring writers back
kubectl -n apps scale deploy/demo-api --replicas=1
```

### Test the restore on a schedule

A backup nobody has restored is a hypothesis. Quarterly, restore the most recent dump into
a scratch database and check that the row counts are plausible:

```console
kubectl -n apps exec postgres-0 -- psql -U demo -d demo -c \
  "select relname, n_live_tup from pg_stat_user_tables order by n_live_tup desc limit 10;"
```

## Certificates

### Check what is issued and when it expires

```console
kubectl get certificate -A
kubectl -n apps get secret app-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -dates
```

### A certificate is stuck in `Ready=False`

```console
kubectl -n apps describe certificate app-tls
kubectl -n apps get certificaterequest
kubectl -n cert-manager logs deploy/cert-manager --tail=50
```

The common causes, in order of likelihood:

- **`renewBefore` is larger than `duration`.** cert-manager rejects the resource outright.
  This happens when shortening a long-lived certificate and forgetting the second field.
- **The ClusterIssuer is not ready** — usually because the root CA Secret does not exist
  yet. Check `kubectl get clusterissuer internal-ca -o wide`.
- **A stale CertificateRequest** is blocking. Delete it; cert-manager creates a new one.

### Force reissue

```console
kubectl -n apps delete secret app-tls
# cert-manager notices the missing secret and reissues within seconds
kubectl -n apps wait --for=condition=Ready certificate/app-tls --timeout=60s
```

## The browser will not open the site

Work down this list; each step rules out one layer.

1. **Does the name resolve?** `make hosts` prints the required `/etc/hosts` line.
2. **Is the certificate trusted?** `make trust-ca` exports the root and prints the install
   command for each platform.
3. **Is the certificate short enough?** Anything over 398 days is rejected by Apple
   clients regardless of trust. Check with `openssl x509 -noout -dates`.
4. **Test with the right tool.** On macOS, `curl` validates against `/etc/ssl/cert.pem`,
   not the system keychain, so it fails even when trust is correctly installed. Use
   `nscurl <url>` — it uses the same evaluation as Safari.
5. **Is the ingress routing?** `kubectl -n apps describe ingress demo-frontend` and check
   the backend has endpoints.

## The UI loads but its API calls fail

Almost always one of two things, and the server logs will show the request *succeeding*,
which is what makes it confusing:

- **The API host's certificate is not trusted.** Browsers do not prompt on `fetch()`; the
  request fails silently and no JavaScript sees the response. Open the API hostname
  directly in a tab — if it warns, that is the cause.
- **CORS.** Check that the Traefik middleware allows the frontend's exact origin,
  including port: `kubectl -n apps get middleware cors -o yaml`.

## A pod will not start

```console
kubectl -n apps get pods
kubectl -n apps describe pod <name>     # events at the bottom explain most failures
kubectl -n apps logs <name> --previous  # the crashed instance, not the restarting one
```

`--previous` is the flag worth remembering: on a crash-looping pod the current container
usually has no useful output, and the reason is in the one that already died.

## Full rebuild

The platform is designed to be disposable. If the state is confusing, rebuilding is faster
than untangling:

```console
make down
make up
```

Application data does not survive this. Restore from a backup afterwards.
