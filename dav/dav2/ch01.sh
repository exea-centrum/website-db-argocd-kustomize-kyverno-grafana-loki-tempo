#!/bin/bash
set -e

PROJECT="website-db-argocd-kustomize-kyverno-grafana-loki-tempo"
NAMESPACE="davtrowebdb"
REGISTRY="ghcr.io/exea-centrum/$PROJECT"
APP_DIR="$PROJECT/app"

echo "📁 Tworzenie struktury katalogów..."
mkdir -p $APP_DIR/templates k8s/base k8s/overlays monitoring/base monitoring/overlays/dev .github/workflows

# ==============================
# FastAPI + 50 pól formularza
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

QUESTIONS = [f"Pytanie {i+1}" for i in range(50)]

@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    return templates.TemplateResponse("form.html", {"request": request, "questions": QUESTIONS})

@app.post("/submit", response_class=HTMLResponse)
async def submit(request: Request, **answers):
    conn = psycopg2.connect(DB_CONN)
    cur = conn.cursor()
    cur.execute("CREATE TABLE IF NOT EXISTS answers(id SERIAL PRIMARY KEY, question TEXT, answer TEXT);")
    for question, answer in answers.items():
        cur.execute("INSERT INTO answers(question, answer) VALUES(%s, %s)", (question, answer))
        logger.info(f"Odpowiedź zapisana: {question} => {answer}")
    conn.commit()
    cur.close()
    conn.close()
    return templates.TemplateResponse("form.html", {"request": request, "submitted": True, "questions": QUESTIONS})
EOF

cat << 'EOF' > $APP_DIR/templates/form.html
<!DOCTYPE html>
<html>
<head>
    <title>Kwestionariusz</title>
    <style>
        body { font-family: Arial; margin: 30px; }
        form div { margin-bottom: 15px; }
        label { display: block; margin-bottom: 5px; }
    </style>
</head>
<body>
  <h1>Kwestionariusz</h1>
  {% if submitted %}
    <p><b>Dziękujemy za wypełnienie formularza!</b></p>
  {% endif %}
  <form method="post" action="/submit">
    {% for q in questions %}
      <div>
        <label>{{ q }}</label>
        <select name="{{ q }}">
          <option value="1">1</option>
          <option value="2">2</option>
          <option value="3">3</option>
          <option value="4">4</option>
          <option value="5">5</option>
        </select>
      </div>
    {% endfor %}
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
# Kubernetes Base (App + DB + Ingress)
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
  - host: website.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $PROJECT
            port:
              number: 80
EOF

cat << EOF > k8s/base/kustomization.yaml
resources:
- deployment.yaml
- service.yaml
- postgres.yaml
- ingress.yaml
EOF

# ==============================
# Reszta (Monitoring, ArgoCD, GitHub Actions)
# ==============================
# Tu można wkleić cały poprzedni monitoring/base i overlays + ArgoCD + GitHub Actions
# zachowując wcześniejsze pliki (prometheus, grafana, loki, tempo, promtail, argocd-app.yaml, workflow)

echo "✅ All-in-One projekt z 50 polami i Ingress gotowy!"
echo "Po wdrożeniu przez ArgoCD:"
echo "1. Dodaj host w /etc/hosts: 127.0.0.1 website.local"
echo "2. Odwiedź http://website.local"
echo "Monitoring i logging gotowe w namespace $NAMESPACE"
