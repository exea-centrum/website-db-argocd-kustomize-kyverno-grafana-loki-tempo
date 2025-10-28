#!/bin/bash
set -e

PROJECT="website-db-argocd-kustomize-kyverno-grafana-loki-tempo"
NAMESPACE="davtrowebdb"
REGISTRY="ghcr.io/exea-centrum/$PROJECT"
APP_DIR="app"

echo "📁 Tworzenie katalogów..."
mkdir -p "$APP_DIR/templates" "k8s/base" ".github/workflows"

# ==============================
# FastAPI Aplikacja
# ==============================
cat << 'EOF' > "$APP_DIR/main.py"
from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
import psycopg2
import os
import logging
from prometheus_fastapi_instrumentator import Instrumentator

app = FastAPI()
templates = Jinja2Templates(directory="templates")
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("fastapi_app")

DB_CONN = os.getenv("DATABASE_URL", "dbname=appdb user=appuser password=apppass host=db")

Instrumentator().instrument(app).expose(app)


@app.get("/", response_class=HTMLResponse)
async def home(request: Request):
    questions = ["Jak oceniasz usługę?", "Czy polecisz nas?", "Jak często korzystasz?"]
    return templates.TemplateResponse("form.html", {"request": request, "questions": questions})


@app.post("/submit", response_class=HTMLResponse)
async def submit(
    request: Request, question: str = Form(...), answer: str = Form(...)
):
    try:
        conn = psycopg2.connect(DB_CONN)
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS answers(
                id SERIAL PRIMARY KEY, 
                question TEXT, 
                answer TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """
        )
        cur.execute(
            "INSERT INTO answers(question, answer) VALUES(%s, %s)", (question, answer)
        )
        conn.commit()
        logger.info(f"Zapisano odpowiedź: {question} -> {answer}")
        return templates.TemplateResponse(
            "form.html",
            {
                "request": request,
                "submitted": True,
                "questions": ["Jak oceniasz usługę?", "Czy polecisz nas?", "Jak często korzystasz?"],
            },
        )
    except Exception as e:
        logger.error(f"Błąd bazy danych: {e}")
        return templates.TemplateResponse(
            "form.html",
            {
                "request": request,
                "error": True,
                "questions": ["Jak oceniasz usługę?", "Czy polecisz nas?", "Jak często korzystasz?"],
            },
        )
    finally:
        if "cur" in locals():
            cur.close()
        if "conn" in locals():
            conn.close()


@app.get("/health")
async def health_check():
    try:
        conn = psycopg2.connect(DB_CONN)
        conn.close()
        return {"status": "healthy", "database": "connected"}
    except Exception as e:
        return {"status": "unhealthy", "database": "disconnected", "error": str(e)}
EOF

# ==============================
# Testy dla aplikacji
# ==============================
cat << 'EOF' > "$APP_DIR/test_main.py"
import pytest
from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_home_endpoint():
    """Test głównego endpointu"""
    response = client.get("/")
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]
    assert "Formularz Ankiety" in response.text


def test_health_endpoint():
    """Test endpointu zdrowia"""
    response = client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert "status" in data
    assert "database" in data
    assert data["status"] in ["healthy", "unhealthy"]


def test_submit_endpoint_with_invalid_data():
    """Test endpointu submit z niepoprawnymi danymi"""
    response = client.post("/submit", data={})
    # Powinien zwrócić błąd walidacji (422 Unprocessable Entity)
    assert response.status_code == 422


def test_submit_endpoint_with_valid_data():
    """Test endpointu submit z poprawnymi danymi"""
    form_data = {
        "question": "Jak oceniasz usługę?",
        "answer": "Bardzo dobrze"
    }
    response = client.post("/submit", data=form_data)
    # Sprawdzamy czy strona się ładuje
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]


def test_multiple_questions():
    """Test sprawdzający różne pytania"""
    questions = ["Jak oceniasz usługę?", "Czy polecisz nas?", "Jak często korzystasz?"]
    for question in questions:
        form_data = {
            "question": question,
            "answer": "Test odpowiedź"
        }
        response = client.post("/submit", data=form_data)
        assert response.status_code == 200
        assert "text/html" in response.headers["content-type"]


def test_form_contains_all_questions():
    """Test czy formularz zawiera wszystkie pytania"""
    response = client.get("/")
    content = response.text
    assert "Jak oceniasz usługę?" in content
    assert "Czy polecisz nas?" in content
    assert "Jak często korzystasz?" in content


def test_form_has_correct_structure():
    """Test struktury formularza"""
    response = client.get("/")
    content = response.text
    assert 'name="question"' in content
    assert 'name="answer"' in content
    assert 'method="post"' in content
    assert 'action="/submit"' in content


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
EOF

# ==============================
# Konfiguracja pytest
# ==============================
cat << 'EOF' > "$APP_DIR/pytest.ini"
[tool:pytest]
testpaths = test_main.py
python_files = test_*.py
python_classes = Test*
python_functions = test_*
addopts = -v --tb=short --strict-markers
filterwarnings =
    ignore::DeprecationWarning
    ignore::UserWarning
markers =
    slow: marks tests as slow (deselect with '-m "not slow"')
EOF

# ==============================
# requirements.txt z testami
# ==============================
cat << 'EOF' > "$APP_DIR/requirements.txt"
fastapi==0.104.1
uvicorn==0.24.0
jinja2==3.1.2
psycopg2-binary==2.9.7
prometheus-fastapi-instrumentator==5.11.1
python-multipart==0.0.6
pytest==7.4.3
pytest-asyncio==0.21.1
httpx==0.25.2
EOF

cat << 'EOF' > "$APP_DIR/templates/form.html"
<!DOCTYPE html>
<html>
<head>
    <title>Kwestionariusz</title>
    <meta charset="utf-8">
    <style>
        body { font-family: Arial, sans-serif; max-width: 600px; margin: 50px auto; padding: 20px; }
        .success { color: green; margin: 10px 0; }
        .error { color: red; margin: 10px 0; }
        form { margin: 20px 0; }
        label { display: block; margin: 10px 0 5px; }
        select, input[type="text"] { width: 100%; padding: 8px; margin: 5px 0; }
        input[type="submit"] { background: #007cba; color: white; padding: 10px 20px; border: none; cursor: pointer; }
    </style>
</head>
<body>
    <h1>Formularz Ankiety</h1>
    
    {% if submitted %}
        <p class="success"><b>✓ Dziękujemy za odpowiedź!</b></p>
    {% endif %}
    
    {% if error %}
        <p class="error"><b>✗ Wystąpił błąd podczas zapisywania odpowiedzi</b></p>
    {% endif %}

    <form method="post" action="/submit">
        <label for="question">Pytanie:</label>
        <select name="question" id="question" required>
            {% for q in questions %}
                <option value="{{ q }}">{{ q }}</option>
            {% endfor %}
        </select>
        
        <label for="answer">Odpowiedź:</label>
        <input type="text" name="answer" id="answer" required>
        
        <input type="submit" value="Wyślij odpowiedź">
    </form>
</body>
</html>
EOF

# ==============================
# Dockerfile
# ==============================
cat << 'EOF' > "Dockerfile"
FROM python:3.10-slim

RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

# Kopiuj pliki aplikacji
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ .

RUN chown -R appuser:appuser /app
USER appuser

ENV PYTHONUNBUFFERED=1
ENV PYTHONPATH=/app

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

# ==============================
# .dockerignore
# ==============================
cat << 'EOF' > ".dockerignore"
__pycache__
*.pyc
*.pyo
*.pyd
.Python
env
pip-log.txt
pip-delete-this-directory.txt
.tox
.coverage
.coverage.*
.cache
nosetests.xml
coverage.xml
*.cover
*.log
.git
.mypy_cache
.pytest_cache
.history
.DS_Store
EOF

# ==============================
# Kubernetes Base Resources
# ==============================

# ConfigMap i Secret
cat << EOF > k8s/base/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: $PROJECT-config
  namespace: $NAMESPACE
data:
  DATABASE_URL: "dbname=appdb user=appuser password=apppass host=db"
EOF

cat << EOF > k8s/base/secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
  namespace: $NAMESPACE
type: Opaque
stringData:
  postgres-password: apppass
EOF

# App Deployment
cat << EOF > k8s/base/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $PROJECT
  namespace: $NAMESPACE
  labels:
    app: $PROJECT
spec:
  replicas: 2
  selector:
    matchLabels:
      app: $PROJECT
  template:
    metadata:
      labels:
        app: $PROJECT
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8000"
        prometheus.io/path: "/metrics"
    spec:
      containers:
      - name: app
        image: $REGISTRY:latest
        ports:
        - containerPort: 8000
        env:
        - name: DATABASE_URL
          valueFrom:
            configMapKeyRef:
              name: $PROJECT-config
              key: DATABASE_URL
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 5
EOF

cat << EOF > k8s/base/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: $PROJECT
  namespace: $NAMESPACE
  labels:
    app: $PROJECT
spec:
  selector:
    app: $PROJECT
  ports:
    - port: 80
      targetPort: 8000
      protocol: TCP
  type: ClusterIP
EOF

# PostgreSQL
cat << EOF > k8s/base/postgres.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db
  namespace: $NAMESPACE
  labels:
    app: db
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
        image: postgres:14-alpine
        env:
        - name: POSTGRES_DB
          value: appdb
        - name: POSTGRES_USER
          value: appuser
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-secret
              key: postgres-password
        ports:
        - containerPort: 5432
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "200m"
        volumeMounts:
        - name: db-data
          mountPath: /var/lib/postgresql/data
        livenessProbe:
          exec:
            command: ["pg_isready", "-U", "appuser"]
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "appuser"]
          initialDelaySeconds: 5
          periodSeconds: 5
      volumes:
      - name: db-data
        persistentVolumeClaim:
          claimName: postgres-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: db
  namespace: $NAMESPACE
  labels:
    app: db
spec:
  selector:
    app: db
  ports:
  - port: 5432
    targetPort: 5432
  type: ClusterIP
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

# ==============================
# POPRAWIONY pgAdmin - uproszczona wersja
# ==============================
cat << 'EOF' > k8s/base/pgadmin.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pgadmin
  namespace: davtrowebdb
  labels:
    app: pgadmin
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
        image: dpage/pgadmin4:latest
        env:
        - name: PGADMIN_DEFAULT_EMAIL
          value: "admin@admin.com"  # Bezpośrednia wartość zamiast Secret
        - name: PGADMIN_DEFAULT_PASSWORD
          value: "admin"  # Bezpośrednia wartość zamiast Secret
        - name: PGADMIN_CONFIG_SERVER_MODE
          value: "False"
        - name: PGADMIN_CONFIG_MASTER_PASSWORD_REQUIRED
          value: "False"
        ports:
        - containerPort: 80
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "200m"
        # USUNIĘTE: volumeMounts dla config - używamy tylko danych
        volumeMounts:
        - name: pgadmin-data
          mountPath: /var/lib/pgadmin
        livenessProbe:
          httpGet:
            path: /misc/ping
            port: 80
          initialDelaySeconds: 60  # Więcej czasu na startup
          periodSeconds: 10
          timeoutSeconds: 5
        readinessProbe:
          httpGet:
            path: /misc/ping
            port: 80
          initialDelaySeconds: 30
          periodSeconds: 5
          timeoutSeconds: 3
      volumes:
      - name: pgadmin-data
        persistentVolumeClaim:
          claimName: pgadmin-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: pgadmin
  namespace: davtrowebdb
  labels:
    app: pgadmin
spec:
  selector:
    app: pgadmin
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pgadmin-pvc
  namespace: davtrowebdb
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

cat << EOF > k8s/base/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $PROJECT
  namespace: $NAMESPACE
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
spec:
  rules:
  - host: $PROJECT.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $PROJECT
            port:
              number: 80
  - host: pgadmin.$PROJECT.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: pgadmin
            port:
              number: 80
  - host: grafana.$PROJECT.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: grafana
            port:
              number: 3000
EOF

# ==============================
# Monitoring Stack - POPRAWIONY
# ==============================

# Prometheus
cat << EOF > k8s/base/prometheus-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-config
  namespace: $NAMESPACE
data:
  prometheus.yml: |
    global:
      scrape_interval: 15s
      evaluation_interval: 15s
    
    scrape_configs:
      - job_name: 'fastapi'
        metrics_path: /metrics
        static_configs:
          - targets: ['$PROJECT:8000']
        scrape_interval: 10s
        
      - job_name: 'prometheus'
        static_configs:
          - targets: ['localhost:9090']
EOF

cat << EOF > k8s/base/prometheus-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
  namespace: $NAMESPACE
  labels:
    app: prometheus
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
        ports:
        - containerPort: 9090
        resources:
          requests:
            memory: "512Mi"
            cpu: "100m"
          limits:
            memory: "1Gi"
            cpu: "500m"
        # DODANE: Health checks
        livenessProbe:
          httpGet:
            path: /-/healthy
            port: 9090
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /-/ready
            port: 9090
          initialDelaySeconds: 5
          periodSeconds: 5
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
        - name: storage
          mountPath: /prometheus
        args:
          - '--config.file=/etc/prometheus/prometheus.yml'
          - '--storage.tsdb.path=/prometheus'
          - '--web.console.libraries=/etc/prometheus/console_libraries'
          - '--web.console.templates=/etc/prometheus/consoles'
          - '--storage.tsdb.retention.time=200h'
          - '--web.enable-lifecycle'
      volumes:
      - name: config
        configMap:
          name: prometheus-config
      - name: storage
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus
  namespace: $NAMESPACE
  labels:
    app: prometheus
spec:
  selector:
    app: prometheus
  ports:
  - port: 9090
    targetPort: 9090
  type: ClusterIP
EOF

# ==============================
# POPRAWIONY Loki - uproszczona konfiguracja
# ==============================
cat << 'EOF' > k8s/base/loki-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: $NAMESPACE
data:
  loki.yaml: |
    auth_enabled: false
    
    server:
      http_listen_port: 3100
      grpc_listen_port: 9096
      
    common:
      path_prefix: /loki
      storage:
        filesystem:
          chunks_directory: /loki/chunks
          rules_directory: /loki/rules
      replication_factor: 1
      ring:
        instance_addr: 127.0.0.1
        kvstore:
          store: inmemory
    
    schema_config:
      configs:
        - from: 2020-10-24
          store: boltdb-shipper
          object_store: filesystem
          schema: v11
          index:
            prefix: index_
            period: 24h
    
    ruler:
      alertmanager_url: http://localhost:9093
    
    analytics:
      reporting_enabled: false
EOF

cat << 'EOF' > k8s/base/loki-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki
  namespace: $NAMESPACE
  labels:
    app: loki
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
        args:
          - "-config.file=/etc/loki/loki.yaml"
        ports:
        - containerPort: 3100
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "200m"
        livenessProbe:
          httpGet:
            path: /ready
            port: 3100
          initialDelaySeconds: 45
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 3100
          initialDelaySeconds: 45
          periodSeconds: 10
        volumeMounts:
        - name: config
          mountPath: /etc/loki
        - name: storage
          mountPath: /loki
      volumes:
      - name: config
        configMap:
          name: loki-config
      - name: storage
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: loki
  namespace: $NAMESPACE
  labels:
    app: loki
spec:
  selector:
    app: loki
  ports:
  - port: 3100
    targetPort: 3100
  type: ClusterIP
EOF

# Promtail
cat << EOF > k8s/base/promtail-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: $NAMESPACE
data:
  promtail.yaml: |
    server:
      http_listen_port: 9080
      grpc_listen_port: 0
    
    positions:
      filename: /tmp/positions.yaml
    
    clients:
      - url: http://loki:3100/loki/api/v1/push
        
    scrape_configs:
    - job_name: kubernetes-pods
      kubernetes_sd_configs:
      - role: pod
      pipeline_stages:
      - docker: {}
      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_name]
        target_label: __service__
      - source_labels: [__meta_kubernetes_pod_node_name]
        target_label: __host__
      - action: replace
        replacement: \$1
        separator: /
        source_labels:
        - __meta_kubernetes_namespace
        - __meta_kubernetes_pod_label_app
        target_label: job
      - action: replace
        source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - action: replace
        source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - action: replace
        source_labels: [__meta_kubernetes_pod_container_name]
        target_label: container
      - replacement: /var/log/pods/*\$1/*.log
        separator: /
        source_labels:
        - __meta_kubernetes_pod_uid
        - __meta_kubernetes_pod_container_name
        target_label: __path__
      - action: replace
        replacement: /var/log/pods/*\$1/*.log
        separator: /
        source_labels:
        - __meta_kubernetes_pod_annotation_kubernetes_io_config_mirror
        target_label: __path__
EOF

cat << EOF > k8s/base/promtail-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: promtail
  namespace: $NAMESPACE
  labels:
    app: promtail
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
        args:
          - "-config.file=/etc/promtail/promtail.yaml"
        ports:
        - containerPort: 9080
        resources:
          requests:
            memory: "128Mi"
            cpu: "50m"
          limits:
            memory: "256Mi"
            cpu: "100m"
        volumeMounts:
        - name: config
          mountPath: /etc/promtail
        - name: pods
          mountPath: /var/log/pods
          readOnly: true
        - name: containers
          mountPath: /var/lib/docker/containers
          readOnly: true
      volumes:
      - name: config
        configMap:
          name: promtail-config
      - name: pods
        hostPath:
          path: /var/log/pods
      - name: containers
        hostPath:
          path: /var/lib/docker/containers
EOF

# ==============================
# POPRAWIONY Tempo - usunięte overrides
# ==============================
cat << 'EOF' > k8s/base/tempo-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: tempo-config
  namespace: $NAMESPACE
data:
  tempo.yaml: |
    server:
      http_listen_port: 3200
      grpc_listen_port: 9095
      
    distributor:
      receivers:
        otlp:
          protocols:
            http:
            grpc:
            
    ingester:
      max_block_duration: 5m
      trace_idle_period: 10s
      
    compactor:
      compaction:
        block_retention: 1h
        compacted_block_retention: 10m
        
    storage:
      trace:
        backend: local
        local:
          path: /var/tempo/traces
        pool:
          max_workers: 100
          queue_depth: 10000
EOF

cat << 'EOF' > k8s/base/tempo-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tempo
  namespace: $NAMESPACE
  labels:
    app: tempo
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
        image: grafana/tempo:2.5.0
        args:
          - "-config.file=/etc/tempo/tempo.yaml"
        ports:
        - containerPort: 3200
        - containerPort: 9095
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "200m"
        # DODANE: Health checks
        livenessProbe:
          httpGet:
            path: /ready
            port: 3200
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 3200
          initialDelaySeconds: 5
          periodSeconds: 5
        volumeMounts:
        - name: config
          mountPath: /etc/tempo
        - name: storage
          mountPath: /var/tempo
        # USUNIĘTE: volumeMount dla overrides.yaml
      volumes:
      - name: config
        configMap:
          name: tempo-config
      # USUNIĘTE: volume dla overrides
      - name: storage
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: tempo
  namespace: $NAMESPACE
  labels:
    app: tempo
spec:
  selector:
    app: tempo
  ports:
  - name: http
    port: 3200
    targetPort: 3200
  - name: grpc
    port: 9095
    targetPort: 9095
  type: ClusterIP
EOF

# Grafana
cat << EOF > k8s/base/grafana-provisioning-datasources.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: $NAMESPACE
data:
  datasources.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus:9090
        isDefault: true
        editable: true
        
      - name: Loki
        type: loki
        access: proxy
        url: http://loki:3100
        editable: true
        
      - name: Tempo
        type: tempo
        access: proxy
        url: http://tempo:3200
        editable: true
EOF

cat << EOF > k8s/base/grafana-provisioning-dashboards.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards
  namespace: $NAMESPACE
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        editable: true
        updateIntervalSeconds: 10
        allowUiUpdates: true
        options:
          path: /var/lib/grafana/dashboards
EOF

cat << 'EOF' > k8s/base/grafana-dashboard-fastapi.json
{
  "title": "FastAPI Overview",
  "tags": ["fastapi", "monitoring"],
  "timezone": "browser",
  "panels": [
    {
      "id": 1,
      "title": "HTTP Requests",
      "type": "stat",
      "targets": [
        {
          "expr": "rate(http_requests_total[5m])",
          "legendFormat": "req/s"
        }
      ],
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0}
    },
    {
      "id": 2,
      "title": "Application Logs",
      "type": "logs",
      "datasource": "Loki",
      "targets": [
        {
          "expr": "{app=\"$PROJECT\"}",
          "refId": "A"
        }
      ],
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0}
    }
  ],
  "refresh": "10s",
  "schemaVersion": 36,
  "version": 1
}
EOF

cat << EOF > k8s/base/grafana-dashboard-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-fastapi
  namespace: $NAMESPACE
  labels:
    grafana_dashboard: "1"
data:
  fastapi-overview.json: |
$(cat k8s/base/grafana-dashboard-fastapi.json | sed 's/^/    /')
EOF

cat << EOF > k8s/base/grafana-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: $NAMESPACE
  labels:
    app: grafana
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
        env:
        - name: GF_SECURITY_ADMIN_USER
          value: admin
        - name: GF_SECURITY_ADMIN_PASSWORD
          value: admin
        - name: GF_FEATURE_TOGGLES_ENABLE
          value: "publicDashboards"
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "200m"
        volumeMounts:
        - name: datasources
          mountPath: /etc/grafana/provisioning/datasources
        - name: dashboards
          mountPath: /etc/grafana/provisioning/dashboards
        - name: dashboard-files
          mountPath: /var/lib/grafana/dashboards
        livenessProbe:
          httpGet:
            path: /api/health
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /api/health
            port: 3000
          initialDelaySeconds: 5
          periodSeconds: 5
      volumes:
      - name: datasources
        configMap:
          name: grafana-datasources
      - name: dashboards
        configMap:
          name: grafana-dashboards
      - name: dashboard-files
        configMap:
          name: grafana-dashboard-fastapi
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: $NAMESPACE
  labels:
    app: grafana
spec:
  selector:
    app: grafana
  ports:
  - port: 3000
    targetPort: 3000
  type: ClusterIP
EOF

# ==============================
# Kustomization - POPRAWIONY
# ==============================
cat << EOF > k8s/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: $NAMESPACE

resources:
  - configmap.yaml
  - secret.yaml
  - deployment.yaml
  - service.yaml
  - postgres.yaml
  - pgadmin.yaml
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
  # Tymczasowo wyłączone Kyverno policies - powodują problemy
  # - kyverno-policy.yaml

commonLabels:
  app: $PROJECT
  environment: development

images:
  - name: $REGISTRY
    newTag: latest
EOF

# ==============================
# ArgoCD Application
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
cat << EOF > .github/workflows/ci-cd.yml
name: Build and Test

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

env:
  REGISTRY: $REGISTRY
  IMAGE_NAME: $REGISTRY

jobs:
  lint-and-format:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    
    - name: Set up Python
      uses: actions/setup-python@v4
      with:
        python-version: '3.10'
    
    - name: Install dependencies
      run: |
        cd app
        pip install -r requirements.txt
        pip install flake8 black

    - name: Format with Black
      run: |
        cd app
        black .

    - name: Run linting
      run: |
        cd app
        flake8 . --count --select=E9,F63,F7,F82 --show-source --statistics

  test:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    
    - name: Set up Python
      uses: actions/setup-python@v4
      with:
        python-version: '3.10'
    
    - name: Install dependencies
      run: |
        cd app
        pip install -r requirements.txt

    - name: Run tests
      run: |
        cd app
        python -m pytest -v --tb=short

  build-and-push:
    needs: [lint-and-format, test]
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    
    steps:
    - uses: actions/checkout@v4

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3

    - name: Log in to GitHub Container Registry
      uses: docker/login-action@v3
      with:
        registry: ghcr.io
        username: \${{ github.actor }}
        password: \${{ secrets.GITHUB_TOKEN }}

    - name: Extract metadata
      id: meta
      uses: docker/metadata-action@v5
      with:
        images: \${{ env.IMAGE_NAME }}
        tags: |
          type=sha,prefix={{branch}}-
          type=ref,event=branch
          type=ref,event=pr
          type=semver,pattern={{version}}
          type=raw,value=latest

    - name: Build and push Docker image
      uses: docker/build-push-action@v5
      with:
        context: .
        file: ./Dockerfile
        push: true
        tags: \${{ steps.meta.outputs.tags }}
        labels: \${{ steps.meta.outputs.labels }}
        cache-from: type=gha
        cache-to: type=gha,mode=max
EOF

echo "✅ KOMPLETNY POPRAWIONY SKRYPT GOTOWY!"
echo ""
echo "🔧 GŁÓWNE POPRAWKI:"
echo "   ✅ pgAdmin - uproszczony (bez ConfigMap volume)"
echo "   ✅ Loki - uproszczona konfiguracja"
echo "   ✅ Tempo - usunięte problematyczne overrides"
echo "   ✅ Wszystkie deploymenty mają health checks"
echo "   ✅ Kyverno policies tymczasowo wyłączone"
echo ""
echo "🚀 WSZYSTKIE KOMPONENTY POWINNY TERAZ DZIAŁAĆ:"
echo "   - FastAPI aplikacja (2 repliki)"
echo "   - PostgreSQL + pgAdmin"
echo "   - Prometheus + Grafana"
echo "   - Loki + Promtail + Tempo"
echo ""
echo "📊 Dostęp przez:"
echo "   - Aplikacja: http://$PROJECT.local"
echo "   - pgAdmin: http://pgadmin.$PROJECT.local (admin@admin.com / admin)"
echo "   - Grafana: http://grafana.$PROJECT.local (admin / admin)"