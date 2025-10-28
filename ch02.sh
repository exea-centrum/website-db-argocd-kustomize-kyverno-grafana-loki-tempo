#!/bin/bash
set -e

PROJECT="website-db-argocd-kustomize-kyverno-grafana-loki-tempo"
NAMESPACE="davtrowebdb"
REGISTRY="ghcr.io/exea-centrum/$PROJECT"
APP_DIR="$PROJECT/app"

echo "📁 Tworzenie katalogów..."
mkdir -p $APP_DIR/templates k8s/base .github/workflows

# ==============================
# FastAPI Aplikacja
# ==============================
cat << 'EOF' > $APP_DIR/main.py
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
import psycopg2, os, logging
from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI()
templates = Jinja2Templates(directory="app/templates")
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("fastapi_app")

DB_CONN = os.getenv("DATABASE_URL", "dbname=appdb user=appuser password=apppass host=db")

Instrumentator().instrument(app).expose(app)

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    questions = ["Jak oceniasz usługę?", "Czy polecisz nas?", "Jak często korzystasz?"]
    return templates.TemplateResponse("form.html", {"request": request, "questions": questions})

@app.post("/submit", response_class=HTMLResponse)
async def submit(request: Request, question: str = Form(...), answer: str = Form(...)):
    conn = psycopg2.connect(DB_CONN)
    cur = conn.cursor()
    cur.execute("CREATE TABLE IF NOT EXISTS answers(id SERIAL PRIMARY KEY, question TEXT, answer TEXT);")
    cur.execute("INSERT INTO answers(question, answer) VALUES(%s, %s)", (question, answer))
    conn.commit()
    cur.close()
    conn.close()
    logger.info(f"Odpowiedź: {question} -> {answer}")
    return templates.TemplateResponse("form.html", {"request": request, "submitted": True, "questions": ["Jak oceniasz usługę?", "Czy polecisz nas?", "Jak często korzystasz?"]})
EOF

cat << 'EOF' > $APP_DIR/templates/form.html
<!DOCTYPE html>
<html>
<head><title>Kwestionariusz</title></head>
<body>
  <h1>Formularz</h1>
  {% if submitted %}
    <p><b>Dziękujemy za odpowiedź!</b></p>
  {% endif %}
  <form method="post" action="/submit">
    <label>Pytanie:</label>
    <select name="question">
      {% for q in questions %}
        <option value="{{q}}">{{q}}</option>
      {% endfor %}
    </select>
    <label>Odpowiedź:</label>
    <input type="text" name="answer"/>
    <input type="submit" value="Wyślij"/>
  </form>
</body>
</html>
EOF

cat << 'EOF' > $APP_DIR/requirements.txt
fastapi
uvicorn
jinja2
psycopg2-binary
prometheus-fastapi-instrumentator
python-multipart
EOF

# ==============================
# Dockerfile
# ==============================
cat << EOF > $PROJECT/Dockerfile
FROM python:3.10-slim
WORKDIR /app
COPY app/ ./app/
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r app/requirements.txt
ENV PYTHONUNBUFFERED=1
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

# ==============================
# Kubernetes Base (App + DB + Monitoring)
# ==============================
cat << EOF > k8s/base/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $PROJECT
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $PROJECT
  template:
    metadata:
      labels:
        app: $PROJECT
    spec:
      containers:
      - name: app
        image: $REGISTRY:latest
        ports:
        - containerPort: 8000
        env:
        - name: DATABASE_URL
          value: "dbname=appdb user=appuser password=apppass host=db"
EOF

cat << EOF > k8s/base/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: $PROJECT
  namespace: $NAMESPACE
spec:
  selector:
    app: $PROJECT
  ports:
    - port: 80
      targetPort: 8000
EOF

# ==============================
# PostgreSQL + pgAdmin
# ==============================
cat << EOF > k8s/base/postgres.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: db
  template:
    metadata:
      labels:
        app: db
    spec:
      containers:
      - name: postgres
        image: postgres:14
        env:
        - name: POSTGRES_DB
          value: appdb
        - name: POSTGRES_USER
          value: appuser
        - name: POSTGRES_PASSWORD
          value: apppass
        ports:
        - containerPort: 5432
---
apiVersion: v1
kind: Service
metadata:
  name: db
  namespace: $NAMESPACE
spec:
  selector:
    app: db
  ports:
  - port: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgadmin
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pgadmin
  template:
    metadata:
      labels:
        app: pgadmin
    spec:
      containers:
      - name: pgadmin
        image: dpage/pgadmin4:8.10
        env:
        - name: PGADMIN_DEFAULT_EMAIL
          value: admin@local
        - name: PGADMIN_DEFAULT_PASSWORD
          value: admin
        ports:
        - containerPort: 80
        volumeMounts:
        - name: pgadmin-data
          mountPath: /var/lib/pgadmin
      volumes:
      - name: pgadmin-data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: pgadmin
  namespace: $NAMESPACE
spec:
  selector:
    app: pgadmin
  ports:
    - port: 5050
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pgadmin
  namespace: $NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - http:
      paths:
      - path: /pgadmin
        pathType: Prefix
        backend:
          service:
            name: pgadmin
            port:
              number: 5050
EOF

# ==============================
# Ingress App
# ==============================
cat << EOF > k8s/base/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $PROJECT
  namespace: $NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $PROJECT
            port:
              number: 80
EOF

# ==============================
# Monitoring (Prometheus, Loki, Tempo, Grafana)
# ==============================

# (... tu zostaje cały Twój monitoring z Prometheus, Loki, Tempo, Grafana jak wcześniej ...)

# ==============================
# Kustomization
# ==============================
cat << EOF > k8s/base/kustomization.yaml
resources:
- deployment.yaml
- service.yaml
- postgres.yaml
- ingress.yaml
- prometheus-config.yaml
- prometheus-deployment.yaml
- grafana-provisioning-datasources.yaml
- grafana-provisioning-dashboards.yaml
- grafana-dashboard-config.yaml
- grafana-deployment.yaml
- loki-config.yaml
- loki-deployment.yaml
- promtail-config.yaml
- promtail-deployment.yaml
- tempo-config.yaml
- tempo-deployment.yaml
EOF

# ==============================
# ArgoCD App
# ==============================
cat << EOF > k8s/base/argocd-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $PROJECT
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/exea-centrum/$PROJECT.git
    targetRevision: main
    path: k8s/base
  destination:
    server: https://kubernetes.default.svc
    namespace: $NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

# ==============================
# GitHub Actions
# ==============================
cat << EOF > .github/workflows/deploy.yml
name: Build and Push
on:
  push:
    branches: [main]
jobs:
  docker:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Login GHCR
        run: echo "\${{ secrets.GHCR_PAT }}" | docker login ghcr.io -u \${{ github.actor }} --password-stdin
      - name: Build & Push
        run: |
          docker build -f $PROJECT/Dockerfile -t $REGISTRY:\${{ github.sha }} -t $REGISTRY:latest $PROJECT
          docker push $REGISTRY:\${{ github.sha }}
          docker push $REGISTRY:latest
EOF

echo "✅ Stack gotowy: PostgreSQL + pgAdmin + Grafana + Loki + Tempo + Prometheus + FastAPI 🎯"
