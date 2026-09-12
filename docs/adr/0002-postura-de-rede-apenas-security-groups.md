# ADR 0002: Controle de tráfego só por Security Groups — sem NACLs nem VPC Flow Logs

## Status

Aceito — 2026-09-07

## Contexto

A VPC provisionada por este repositório (ADR 0001) define subnets, tabelas de rotas, Internet Gateway e NAT Gateway (`networking.tf`), mas nenhum `aws_network_acl` customizado nem `aws_flow_log`. O controle de tráfego de entrada/saída fica inteiramente a cargo dos **Security Groups** definidos nos repositórios consumidores (`oficina-mecanica-infra-k8s` para o control plane do EKS, `oficina-mecanica-infra-database` para o RDS) — cada um restringindo tráfego por porta e CIDR de origem no nível de instância/ENI, não no nível de subnet.

## Decisão

Não provisionar **Network ACLs customizadas** (permanecendo com a NACL default da VPC, que permite todo tráfego) nem **VPC Flow Logs**, deixando toda a postura de segurança de rede a cargo dos Security Groups definidos por cada repositório consumidor de recurso.

## Alternativas consideradas

### NACLs customizadas por subnet (camada adicional de filtragem stateless)

Adicionaria uma segunda camada de controle de tráfego, no nível de subnet, independente dos Security Groups — defesa em profundidade clássica. Descartada nesta entrega porque NACLs são stateless (exigem regras explícitas de entrada e saída para cada fluxo, dobrando a superfície de configuração a manter sincronizada com os Security Groups) e, para uma topologia de 2 subnets públicas e 2 privadas com poucos serviços (EKS, RDS), o Security Group já cobre o requisito de restringir tráfego por porta/origem sem a complexidade adicional de manter duas camadas coerentes entre si.

### VPC Flow Logs para toda a VPC

Daria visibilidade de auditoria sobre todo o tráfego de rede (aceito/rejeitado, origem/destino, porta), essencial para investigar incidentes de segurança ou tráfego anômalo. Descartado nesta entrega por custo: Flow Logs gravados no CloudWatch Logs ou S3 têm custo de ingestão e armazenamento contínuo, proporcional ao volume de tráfego — para um ambiente de laboratório com orçamento de crédito limitado (ver ADR 0001), esse custo recorrente não se justificava frente ao ganho de visibilidade, dado que o projeto já não tem processo de resposta a incidente que consumiria esses logs.

## Consequências

### Positivas

- **Configuração de rede mais simples**: uma única camada de controle de tráfego (Security Groups) para revisar e manter, sem exigir sincronização entre duas camadas de regras (NACL + SG) que poderiam divergir silenciosamente.
- **Sem custo recorrente de ingestão/armazenamento de logs de rede**, mantendo o consumo de crédito de laboratório focado no cluster EKS e no RDS.

### Negativas / Trade-offs

- **Sem defesa em profundidade na camada de rede**: se um Security Group for configurado incorretamente (ex.: uma porta liberada além do necessário), não há uma segunda camada (NACL) para conter o erro — o Security Group é a única barreira.
- **Sem visibilidade de auditoria de tráfego de rede**: não há como investigar, a partir da VPC, que tráfego foi aceito ou rejeitado ao longo do tempo — qualquer investigação de incidente de rede dependeria de logs de aplicação ou do CloudTrail, não de Flow Logs.

### Riscos aceitos

- **Ausência de segunda camada de filtragem**: aceito porque o número de serviços expostos é pequeno (EKS control plane, RDS) e cada Security Group já restringe explicitamente porta e CIDR de origem — o ganho marginal de uma NACL customizada, para essa topologia pequena, não compensa a complexidade adicional.
- **Ausência de log de fluxo de rede para auditoria**: aceito por custo, no contexto de laboratório; uma conta de produção real deveria reavaliar essa decisão, habilitando Flow Logs ao menos nas subnets privadas onde o RDS e os nós do EKS residem.

## Referências

- [ADR 0001 — Escolha da nuvem e criação da infraestrutura de rede base](0001-escolha-de-nuvem-e-infra-base.md)
- `terraform/networking.tf` — VPC, subnets, IGW, NAT Gateway, tabelas de rotas (sem NACL nem Flow Log).
- [`oficina-mecanica-infra-k8s` — Security Group do control plane EKS](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-k8s/blob/main/terraform/eks.tf)
- [`oficina-mecanica-infra-database` — Security Group do RDS](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-database/blob/main/terraform/security_group.tf)
