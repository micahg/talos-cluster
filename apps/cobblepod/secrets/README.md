# Sealed secrets for cobblepod

One directory per environment (`dev/`). Files only decrypt on their own cluster. The
`cobblepod-secrets` Argo app applies them into the `cobblepod-dev` namespace.

The chart expects one Secret (see `chart/values-dev.yaml` in the cobblepod repo):

| Secret | Key |
| --- | --- |
| `cobblepod-secrets` | `auth0-client-secret` (the Auth0 M2M application's client secret) |

Create it (the plaintext never touches Git or disk; paste the value at the prompt):

    printf 'Auth0 M2M client secret: '; read -rs S; echo
    kubectl -n cobblepod-dev create secret generic cobblepod-secrets \
      --from-literal=auth0-client-secret="$S" --dry-run=client -o yaml \
    | kubeseal --controller-namespace kube-system --controller-name sealed-secrets-controller \
        --format yaml > dev/cobblepod-secrets.yaml
    unset S
