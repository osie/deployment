<p align="center">
  <img alt="OSIE" src=".github/assets/osie-logo-light.svg#gh-light-mode-only" width="180">
  <img alt="OSIE" src=".github/assets/osie-logo-dark.svg#gh-dark-mode-only" width="180">
</p>

<h1 align="center">OSIE Deployment</h1>

<p align="center">
  <strong>Install OSIE, the OpenStack dashboard and billing system</strong><br>
  On Kubernetes with Helm, or on a single VM with Docker Compose
</p>

<p align="center">
  <a href="https://github.com/osie-io/osie-helm"><img alt="Helm chart" src="https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fhelm.osie.io%2Findex.yaml&query=%24.entries.osie%5B0%5D.version&label=helm%20chart&color=4F52C9"></a>
  <a href="https://osie.io/docs/"><img alt="Documentation" src="https://img.shields.io/badge/docs-osie.io-4F52C9"></a>
</p>

<p align="center">
  <a href="#kubernetes"><strong>Kubernetes</strong></a>
  &nbsp;·&nbsp;
  <a href="#docker-compose">Docker Compose</a>
  &nbsp;·&nbsp;
  <a href="#repository-layout">Repository layout</a>
  &nbsp;·&nbsp;
  <a href="#documentation">Documentation</a>
</p>

<br>

> [!IMPORTANT]
> On the MongoDB, RabbitMQ or Keycloak bundled with chart 26.8.2 or earlier? Move off them first with
> [migrate-bundled](kubernetes/migrate-bundled/README.md).

## About

[OSIE](https://osie.io) is the dashboard and billing system for OpenStack clouds: a client portal, an
admin dashboard and the API behind both. This repository holds the two ways to install it.

| | Kubernetes | Docker Compose |
|---|---|---|
| For | production | one VM, a trial or a small install |
| Runs | the [OSIE Helm chart](https://github.com/osie-io/osie-helm), with MongoDB and RabbitMQ from their operators | osie-api, osie-ui, osie-admin, MongoDB, RabbitMQ and Caddy |
| TLS | your ingress controller or Gateway | Caddy, with Let's Encrypt for a domain or a self-signed certificate for an IP address |
| High availability | a 3-member MongoDB replica set and a 3-node RabbitMQ cluster | no |
| Guide | [kubernetes/README.md](kubernetes/README.md) | [docker-compose/README.md](docker-compose/README.md) |

## Kubernetes

Three steps, each in [kubernetes/README.md](kubernetes/README.md):

1. **Operators.** Install the Percona MongoDB operator and the RabbitMQ cluster operator.
2. **Databases.** Apply the MongoDB and RabbitMQ resources from `kubernetes/infrastructure/`, as a
   single node or highly available.
3. **OSIE.** Install the chart with [values.example.yaml](kubernetes/values.example.yaml), which reads
   the database credentials from the Secrets the operators create:

   ```bash
   helm repo add osie https://helm.osie.io
   helm install osie osie/osie --namespace osie -f kubernetes/values.example.yaml
   ```

The chart deploys only OSIE. Its [README](https://github.com/osie-io/osie-helm#readme) covers the
Gateway API, TLS to MongoDB and RabbitMQ, and every setting.

## Docker Compose

An interactive installer sets up Docker, TLS, secrets and the services on one Debian, Ubuntu or RHEL
family VM:

```bash
wget https://raw.githubusercontent.com/osie/deployment/main/docker-compose/install.sh
sudo bash install.sh
```

It asks for a public domain or an IP address, checks DNS for a domain, installs Docker if needed and
starts everything from `/opt/osie`. `--hostname <domain>` runs it without questions.
[docker-compose/README.md](docker-compose/README.md) has every option and the day-to-day commands.

## Repository layout

```
kubernetes/
├── infrastructure/                 # MongoDB and RabbitMQ resources, single node or HA
├── values.example.yaml             # chart values for the operator-managed databases
├── migrate-bundled/                # migrate.sh, its README and its test bench
└── README.md
docker-compose/
├── install.sh                      # the single-VM installer
├── docker-compose.base.yml         # OSIE, MongoDB and RabbitMQ
├── docker-compose.caddy.prod.yml   # Caddy in front, with TLS
├── caddy/ config/
└── README.md
```

## Documentation

- [OSIE documentation](https://osie.io/docs/)
- [Installing OSIE on Kubernetes](https://osie.io/docs/operators-manual/kubernetes-install/)
- [osie-io/osie-helm](https://github.com/osie-io/osie-helm), the Helm chart
