# sw-update-devops

Infrastructure for **[SW Update Manager](https://github.com/tareqa2/sw-update)**: Kubernetes manifests, nginx reverse proxy and the in-cluster CI runner.
The application code, Dockerfile and pipelines live in the app repo.

## What runs where

```
Minikube cluster
├── namespace sw-update                (the app - k8s/)
│   ├── sw-nginx     Deployment x2  +  Service NodePort 30080   <- the only way in
│   ├── sw-backend   Deployment x1  +  Service ClusterIP :8000
│   ├── sw-backend-data  PVC 1Gi    (CSV files)
│   ├── sw-backend-config  ConfigMap   sw-nginx-config  ConfigMap
│   └── sw-backend-secret  Secret  (created by the pipeline / CLI - never in git)
└── namespace gh-runner                (CI - k8s-runner/)
    └── gh-runner  Deployment x1     self-hosted GitHub Actions runner
        ServiceAccount + RBAC: may manage resources in sw-update only
```

## Design decisions

| Decision | Why |
|---|---|
| Backend: **1 replica, `Recreate` strategy** | CSV files on a `ReadWriteOnce` volume must have a single writer; two pods writing at once could corrupt them |
| nginx: **2 replicas, `RollingUpdate` (maxUnavailable 0)** | Stateless, so it scales freely and updates with zero downtime |
| Backend Service is **ClusterIP**, nginx is **NodePort** | Users can only reach the app through nginx |
| nginx **blocks `/metrics`** | Metrics are for Prometheus inside the cluster, not the internet |
| nginx **caches `/static/`** | Repeat image requests never reach Flask (`X-Cache-Status: HIT`) |
| **Liveness `/healthz`, readiness `/readyz`, startup probe** | Hung process -> restart; storage not writable -> no traffic; slow boot -> no false restarts |
| **requests/limits** on every container | Fair scheduling and a hard ceiling per pod |
| **Non-root, read-only root filesystem, all capabilities dropped, seccomp RuntimeDefault** | Least privilege: only `/data` and `/tmp` are writable |
| **Image tag = commit SHA** set in `kustomization.yaml` | Every deploy maps to an exact commit; rollback = previous SHA |
| CI runner **inside the cluster** | Windows Smart App Control blocks the Windows runner binary; a pod also needs no kubeconfig and reaches services by cluster DNS |
| Runner RBAC **scoped to `sw-update`** | The pipeline can deploy the app and nothing else |

## Deploy by hand

Prerequisites: Docker Desktop, Minikube, kubectl.

```powershell
minikube start --driver=docker --cpus=2 --memory=4096

# 1. Namespace and the app Secret (random key, never written to a file)
kubectl apply -f k8s/namespace.yaml
$key = python -c "import secrets; print(secrets.token_hex(32))"
kubectl -n sw-update create secret generic sw-backend-secret --from-literal=SECRET_KEY=$key

# 2. Everything else, in one command
kubectl apply -k k8s/
kubectl -n sw-update rollout status deploy/sw-backend
kubectl -n sw-update get pods,svc,pvc

# 3. Open it (Docker driver on Windows needs a tunnel - keep this terminal open)
minikube service sw-nginx -n sw-update --url
```

To deploy a specific build, set `newTag` in `k8s/kustomization.yaml` to that commit SHA and run `kubectl apply -k k8s/` again.

## CI runner (one-time setup)

1. GitHub -> `sw-update` -> Settings -> Actions -> Runners -> **New self-hosted runner** -> Linux -> copy the token after `--token`.
2. Deploy the runner:

```powershell
kubectl apply -f k8s-runner/namespace.yaml
kubectl -n gh-runner create secret generic gh-runner-token --from-literal=RUNNER_TOKEN=<token>
kubectl apply -k k8s-runner/
kubectl -n gh-runner logs deploy/gh-runner --tail=15     # expect "Listening for Jobs"
```

3. Check the RBAC boundary:

```powershell
kubectl auth can-i patch deployments -n sw-update   --as=system:serviceaccount:gh-runner:gh-runner   # yes
kubectl auth can-i patch deployments -n kube-system --as=system:serviceaccount:gh-runner:gh-runner   # no
```

The registration token is single-use and expires after one hour. If the runner pod is ever recreated, create a fresh token, replace the Secret and run `kubectl -n gh-runner rollout restart deploy/gh-runner`.

## Troubleshooting

| Symptom | Check |
|---|---|
| Pod `Pending` | `kubectl -n sw-update describe pod <name>` -> Events (PVC not bound? not enough CPU?) |
| Pod `ImagePullBackOff` | Does the tag in `kustomization.yaml` exist on Docker Hub? |
| Backend `0/1 Ready` | `kubectl -n sw-update logs deploy/sw-backend`; readiness fails if `/data` is not writable |
| Browser can't connect | The `minikube service ... --url` terminal must stay open |
