# website-db-argocd-kustomize-kyverno-grafana-loki-tempo

Full-stack aplikacja z monitoring stack (Grafana, Loki, Tempo, Prometheus), pgAdmin i GitOps (ArgoCD)

## Struktura projektu

```
.
├── website-db-argocd-kustomize-kyverno-grafana-loki-tempo/
│   ├── app/
│   │   ├── main.py
│   │   ├── requirements.txt
│   │   └── templates/
│   │       └── form.html
│   └── Dockerfile
├── k8s/base/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── postgres.yaml
│   ├── pgadmin.yaml
│   ├── configmap.yaml
│   ├── secret.yaml
│   └── kyverno-policy.yaml
└── .github/workflows/
    └── ci-cd.yml
```

## Wymagania

- Kubernetes 1.24+
- ArgoCD
- Kyverno
- Ingress NGINX Controller

## Deployment

Aplikacja jest automatycznie budowana i deployowana przez GitHub Actions przy pushu do main.

### Ręczny deployment:

```bash
kubectl apply -f k8s/base/argocd-app.yaml
```

## Dostęp

- **Aplikacja**: http://website-db-argocd-kustomize-kyverno-grafana-loki-tempo.local
- **pgAdmin**: http://pgadmin.website-db-argocd-kustomize-kyverno-grafana-loki-tempo.local
- **Grafana**: http://grafana.website-db-argocd-kustomize-kyverno-grafana-loki-tempo.local
- **ArgoCD**: http://argocd.website-db-argocd-kustomize-kyverno-grafana-loki-tempo.local

### Dane logowania pgAdmin:
- **Email**: admin@admin.com
- **Password**: admin

### Konfiguracja połączenia w pgAdmin:
1. Logowanie do pgAdmin
2. Kliknij "Add New Server"
3. W zakładce "Connection":
   - **Host**: db
   - **Port**: 5432
   - **Database**: appdb
   - **Username**: appuser
   - **Password**: apppass

## Monitoring Stack

- **Grafana**: Wizualizacja metryk i logów
- **Loki**: Zbieranie logów
- **Tempo**: Distributed tracing
- **Prometheus**: Metryki aplikacji
- **pgAdmin**: Zarządzanie bazą danych PostgreSQL

## Zabezpieczenia

- Kyverno policies wymuszające limity zasobów i health checks
- Resource quotas
- Security contexts
- Secrets dla haseł

## Uwagi

- W środowisku produkcyjnym zmień domyślne hasła w secret.yaml
- pgAdmin przechowuje dane w persistent volume
- Wszystkie komponenty mają skonfigurowane health checks
