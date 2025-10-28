#!/bin/bash
set -e

PROJECT="website-db-argocd-kustomize-kyverno-grafana-loki-tempo"
NAMESPACE="davtrowebdb"

# ==============================
# Poprawiona konfiguracja Tempo
# ==============================

# Tempo Config - uproszczona bez overrides
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

# Tempo Deployment - naprawiony (usunięte overrides)
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

# Zaktualizowany kustomization.yaml - usuń tempo-overrides
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
  # USUNIĘTE: tempo-overrides.yaml
  - tempo-deployment.yaml
  - kyverno-policy.yaml

commonLabels:
  app: $PROJECT
  environment: development

images:
  - name: ghcr.io/exea-centrum/$PROJECT
    newTag: latest
EOF

echo "✅ POPRAWIONO konfigurację Tempo!"
echo "🔧 Zmiany:"
echo "   - Usunięto tempo-overrides.yaml (niepotrzebne)"
echo "   - Usunięto konfliktujące volumeMounts"
echo "   - Uproszczono konfigurację Tempo"
echo ""
echo "🚀 Aby zastosować poprawki:"
echo "   1. Usuń obecny pod Tempo:"
echo "      kubectl delete pod -l app=tempo -n $NAMESPACE"
echo "   2. ArgoCD automatycznie utworzy nowy pod z poprawioną konfiguracją"
echo ""
echo "📝 Alternatywnie, możesz zsynchronizować aplikację w ArgoCD:"
echo "   - Otwórz ArgoCD UI"
echo "   - Kliknij 'Refresh' a potem 'Sync'"