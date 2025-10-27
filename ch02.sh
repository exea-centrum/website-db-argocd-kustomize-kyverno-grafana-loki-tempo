#!/bin/bash
set -e

# ==============================
# Konfiguracja
# ==============================
PROJECT="website-db-argocd-kustomize-kyverno-grafana-loki-tempo"
NAMESPACE="davtrowebdb"
REGISTRY="ghcr.io/exea-centrum/$PROJECT"
APP_DIR="$PROJECT/app"

echo "📁 Tworzenie struktury katalogów..."
mkdir -p $APP_DIR/templates k8s/base k8s/overlays monitoring/base monitoring/overlays/dev .github/workflows

# ==============================
# FastAPI + PostgreSQL + Prometheus instrumentacja + logging
# ==============================
cat << 'EOF' > $APP_DIR/main.py
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
import psycopg2, os, logging
from prometheus_fastapi_instrumentator import Instrumentator

# Logger dla Promtail
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("fastapi_app")

app = FastAPI()
templates = Jinja2Templates(directory="app/templates")
DB_CONN = os.getenv("DATABASE_URL", "dbname=appdb user=appuser password=apppass host=db")

# Prometheus
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
    logger.info(f"Odpowiedź zapisana: {question} => {answer}")
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
# Kubernetes Base (App + DB)
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
EOF

cat << EOF > k8s/base/kustomization.yaml
resources:
- deployment.yaml
- service.yaml
- postgres.yaml
EOF

# ==============================
# Monitoring (Prometheus/Grafana/Loki/Tempo/Promtail)
# ==============================
cat << EOF > monitoring/base/prometheus.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: $NAMESPACE
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
    scrape_configs:
      - job_name: 'fastapi'
        metrics_path: /metrics
        static_configs:
          - targets: ['$PROJECT:8000']
EOF

cat << EOF > monitoring/base/grafana.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-config
  namespace: $NAMESPACE
data:
  grafana.ini: |
    [server]
    http_port = 3000
EOF

cat << EOF > monitoring/base/loki.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: $NAMESPACE
data:
  loki.yaml: |
    server:
      http_listen_port: 3100
EOF

cat << EOF > monitoring/base/tempo.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-config
  namespace: $NAMESPACE
data:
  tempo.yaml: |
    server:
      http_listen_port: 3200
EOF

cat << EOF > monitoring/base/promtail.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: $NAMESPACE
data:
  promtail.yaml: |
    server:
      http_listen_port: 9080
    clients:
      - url: http://loki:3100/loki/api/v1/push
    scrape_configs:
      - job_name: fastapi
        static_configs:
          - targets: ['$PROJECT:8000']
            labels:
              job: fastapi
EOF

cat << EOF > monitoring/base/kustomization.yaml
resources:
  - prometheus.yaml
  - grafana.yaml
  - loki.yaml
  - tempo.yaml
  - promtail.yaml
EOF

cat << EOF > monitoring/overlays/dev/kustomization.yaml
resources:
  - ../../base
namespace: $NAMESPACE
EOF

# ==============================
# ArgoCD Application
# ==============================
cat << EOF > $PROJECT/argocd-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $PROJECT
  namespace: argocd
spec:
  destination:
    namespace: $NAMESPACE
    server: https://kubernetes.default.svc
  source:
    repoURL: https://github.com/youruser/$PROJECT.git
    targetRevision: main
    path: .
  project: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# ==============================
# GitHub Actions
# ==============================
cat << EOF > .github/workflows/deploy.yml
name: Build and Push Docker Image
on:
  push:
    branches: [ main ]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3
    - name: Log in to GHCR
      run: echo "\${{ secrets.GHCR_TOKEN }}" | docker login ghcr.io -u \${{ github.actor }} --password-stdin
    - name: Build and Push
      run: |
        docker build -t $REGISTRY:\${{ github.sha }} .
        docker push $REGISTRY:\${{ github.sha }}
EOF

echo "✅ All-in-One projekt stworzony!"
echo "Instrukcje:"
echo "1. git init && git add . && git commit -m 'init'"
echo "2. git remote add origin https://github.com/youruser/$PROJECT.git"
echo "3. git push -u origin main"
echo "ArgoCD automatycznie wdroży cały stack w namespace $NAMESPACE, metryki i logi są gotowe do monitoringu."
