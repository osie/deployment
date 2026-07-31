# OSIE Kubernetes Deployment

Deploy OSIE infrastructure (MongoDB + RabbitMQ) using Kubernetes operators.

## Prerequisites

- Kubernetes cluster (1.30+)
- `kubectl` configured
- `helm` v3 installed

## 1. Deploy Operators

Operators extend Kubernetes with custom controllers that know how to manage stateful workloads.
The Percona operator handles MongoDB replica set initialization, credential generation, scaling, and backups.
The RabbitMQ operator manages cluster formation, plugin configuration, and rolling upgrades.
Without these, you'd need to manually orchestrate all of this yourself.

```bash
# Percona MongoDB Operator
helm repo add percona https://percona.github.io/percona-helm-charts
helm repo update
helm install percona-mongodb-operator percona/psmdb-operator \
  --namespace percona-mongodb \
  --create-namespace \
  --version 1.22.0 \
  --set watchAllNamespaces=true

# RabbitMQ Cluster Operator
kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/download/v2.20.0/cluster-operator.yml

# Wait for operators to be ready
kubectl wait deployment percona-mongodb-operator-psmdb-operator \
  -n percona-mongodb \
  --for=condition=Available \
  --timeout=300s
kubectl wait deployment rabbitmq-cluster-operator \
  -n rabbitmq-system \
  --for=condition=Available \
  --timeout=300s
```

## 2. Deploy Databases

With the operators running, applying a custom resource (CR) tells each operator what to provision.
The Percona `PerconaServerMongoDB` CR creates a MongoDB replica set with persistent storage and auto-generated credentials.
The `RabbitmqCluster` CR creates a RabbitMQ cluster with management and Prometheus plugins enabled.
The `kubectl wait` commands block until the operators report the clusters are healthy — ensuring the databases are actually accepting connections before you move on to deploying OSIE.

```bash
# Create namespace
kubectl apply -f infrastructure/namespace.yml

# Deploy MongoDB
kubectl apply -f infrastructure/percona-mongodb/psmdb.single-node.yml   # single node, minimal resources
#kubectl apply -f infrastructure/percona-mongodb/psmdb.ha.yml           # 3-node replica set with S3 backups

# Deploy RabbitMQ
kubectl apply -f infrastructure/rabbitmq/rabbitmq.single-node.yml       # single node, minimal resources
#kubectl apply -f infrastructure/rabbitmq/rabbitmq.ha.yml               # 3-node cluster

# Wait for both to be ready
kubectl wait --for=jsonpath='{.status.state}'=ready psmdb/mongodb -n osie --timeout=300s
kubectl wait rabbitmqcluster/rabbitmq -n osie --for=condition=AllReplicasReady --timeout=300s
```

## 3. Deploy OSIE (Helm)

The OSIE Helm chart connects to the operator-managed databases via `existingSecret` references — no need to copy passwords into your values file.

```bash
# Add the OSIE Helm repo (adjust URL to your registry)
helm repo add osie https://helm.osie.io
helm repo update

# Review and edit values.example.yaml
# Then install:
helm install osie osie/osie \
  --namespace osie \
  -f values.example.yaml
```

See [values.example.yaml](values.example.yaml) for the full configuration. Credentials are referenced via `existingSecret` — no manual retrieval needed.

## File Structure

```
kubernetes/
├── README.md
├── values.example.yaml                   # OSIE Helm values for operator-managed DBs
└── infrastructure/
    ├── namespace.yml
    ├── percona-mongodb/
    │   ├── psmdb.single-node.yml         # 3 replicas on same node, minimal resources
    │   └── psmdb.ha.yml                  # 3-node replica set with S3 backups
    └── rabbitmq/
        ├── rabbitmq.single-node.yml      # Single node, minimal resources
        └── rabbitmq.ha.yml              # 3-node cluster
```
