# cloudflared (Cloudflare Tunnel)

One remotely-managed tunnel per cluster. The tunnel token is the only secret; seal it:

    read -rs TOKEN
    kubectl -n cloudflared create secret generic tunnel-token \
      --from-literal=token="$TOKEN" --dry-run=client -o yaml \
    | kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller \
        --format yaml > dev/tunnel-token.yaml
    unset TOKEN

Public hostnames (set in the Cloudflare Zero Trust dashboard, not in Git):

| Hostname | Service |
| --- | --- |
| dev.tbltp.dev | `http://ntt-ui-service.ntt.svc.cluster.local:80` |
| dev-api.tbltp.dev | `http://ntt-api-service.ntt.svc.cluster.local:80` |

cobblepod (hostname to be set; one hostname, two path routes, `/api*` first):

| Path | Service |
| --- | --- |
| `/api*` | `http://cobblepod-server.cobblepod-dev.svc.cluster.local:80` |
| everything else | `http://cobblepod-ui.cobblepod-dev.svc.cluster.local:80` |

## Prod

`apps/cloudflared/prod/` is the same Deployment and policy (no cobblepod). Create a separate
tunnel for prod in Zero Trust and seal its token into `apps/cloudflared/prod/tunnel-token.yaml`
with the recipe above, using the prod cluster's kubeconfig (`KUBECONFIG=~/.kube/talos-prod.config`).
Routes while DOKS still serves prod:

| Hostname | Service |
| --- | --- |
| prod.tbltp.dev | `http://ntt-ui-service.ntt.svc.cluster.local:80` |
| prod-api.tbltp.dev | `http://ntt-api-service.ntt.svc.cluster.local:80` |

At cutover the hostnames become `tbltp.dev` and `api.tbltp.dev` (delete the old DNS records
first), and `uiDomain`/`apiDomain` in `chart/values-talos-prod.yaml` change with them.
