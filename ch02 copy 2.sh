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
mkdir -p $APP_DIR/templates k8s/base .github/workflows

# ==============================
# FastAPI + PostgreSQL + Prometheus instrumentation + logging
# ==============================
cat << 'EOF' > $APP_DIR/main.py
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
import psycopg2, os, logging
from prometheus_fastapi_instrumentator import Instrumentator

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("fastapi_app")

app = FastAPI()
templates = Jinja2Templates(directory="app/templates")
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
# Kubernetes Base (App + DB + Monitoring + Ingress)
# ==============================
cd k8s/base

# ----- FastAPI Deployment -----
cat << EOF > deployment.yaml
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

cat << EOF > service.yaml
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

# ----- PostgreSQL Deployment -----
cat << EOF > postgres.yaml
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

# ----- Ingress -----
cat << EOF > ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $PROJECT
  namespace: $NAMESPACE
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

# ----- Prometheus -----
cat << EOF > prometheus-config.yaml
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

cat << EOF > prometheus-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    metadata:
      labels:
        app: prometheus
    spec:
      containers:
      - name: prometheus
        image: prom/prometheus:latest
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
      volumes:
      - name: config
        configMap:
          name: prometheus-config
EOF

# ----- Grafana -----
cat << EOF > grafana-config.yaml
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

cat << EOF > grafana-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
      - name: grafana
        image: grafana/grafana:latest
        ports:
        - containerPort: 3000
        volumeMounts:
        - name: config
          mountPath: /etc/grafana
      volumes:
      - name: config
        configMap:
          name: grafana-config
EOF

# ----- Loki -----
cat << EOF > loki-config.yaml
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

cat << EOF > loki-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: loki
  template:
    metadata:
      labels:
        app: loki
    spec:
      containers:
      - name: loki
        image: grafana/loki:2.9.0
        ports:
        - containerPort: 3100
        volumeMounts:
        - name: config
          mountPath: /etc/loki
      volumes:
      - name: config
        configMap:
          name: loki-config
EOF

# ----- Tempo -----
cat << EOF > tempo-config.yaml
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

cat << EOF > tempo-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tempo
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: tempo
  template:
    metadata:
      labels:
        app: tempo
    spec:
      containers:
      - name: tempo
        image: grafana/tempo:1.6.0
        ports:
        - containerPort: 3200
        volumeMounts:
        - name: config
          mountPath: /etc/tempo
      volumes:
      - name: config
        configMap:
          name: tempo-config
EOF

# ----- Promtail -----
cat << EOF > promtail-config.yaml
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

cat << EOF > promtail-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: promtail
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: promtail
  template:
    metadata:
      labels:
        app: promtail
    spec:
      containers:
      - name: promtail
        image: grafana/promtail:2.9.0
        ports:
        - containerPort: 9080
        volumeMounts:
        - name: config
          mountPath: /etc/promtail
      volumes:
      - name: config
        configMap:
          name: promtail-config
EOF

# ----- Kustomization -----
cat << EOF > kustomization.yaml
resources:
- deployment.yaml
- service.yaml
- postgres.yaml
- ingress.yaml
- prometheus-config.yaml
- prometheus-deployment.yaml
- grafana-config.yaml
- grafana-deployment.yaml
- loki-config.yaml
- loki-deployment.yaml
- tempo-config.yaml
- tempo-deployment.yaml
- promtail-config.yaml
- promtail-deployment.yaml
EOF

cd ../../../

echo "✅ All-in-One Kubernetes manifests gotowe dla ArgoCD w k8s/base"
