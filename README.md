# OSIE Deployment

## Docker Compose (Single VM)

The quickest way to get OSIE running. An interactive installer handles Docker setup, TLS (Let's Encrypt or self-signed), secret generation, and service orchestration.

```bash
wget https://raw.githubusercontent.com/osie/deployment/main/docker-compose/install.sh
sudo bash install.sh
```

[Full documentation](docker-compose/README.md)

## Kubernetes (Helm)

Production-grade deployment using Percona MongoDB Operator, RabbitMQ Cluster Operator, and the OSIE Helm chart. Supports single-node and HA configurations.

```bash
helm install osie osie/osie --namespace osie -f values.example.yaml
```

[Full documentation](kubernetes/README.md)
