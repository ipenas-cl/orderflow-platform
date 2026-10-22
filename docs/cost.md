# Cost estimate (prod)

Laid out like `infracost breakdown --path terraform/envs/prod`, but
**computed by hand** from AWS public on-demand list prices (us-east-1 /
us-west-2, Linux, USD/month = hourly × 730). infracost was not run: it needs
an API key. With `INFRACOST_API_KEY` set, `make cost` produces the real
breakdown from the Terraform plan.

Usage assumptions (marked ★) are mine and drive most of the variable lines:
★ 3 Karpenter nodes in the primary, 1 in DR; ★ 200 GB Aurora storage;
★ 300 M Aurora I/Os/month; ★ 1 TB NAT data; ★ 50 M WAF requests; ★ 100 GB logs.

| Name | Monthly qty | Unit | Monthly cost |
|---|---:|---|---:|
| **module.primary (us-east-1)** | | | |
| └ EKS cluster | 730 | hours | $73.00 |
| └ system node group: 2 × m7g.large | 1,460 | hours | $119.14 |
| └ Karpenter nodes: 3 × m7g.xlarge (on-demand price; spot is ~60% less) ★ | 2,190 | hours | $357.41 |
| └ NAT gateways × 3 (one per AZ) | 2,190 | hours | $98.55 |
| └ NAT data processed ★ | 1,000 | GB | $45.00 |
| └ ALB (via LB controller) | 730 | hours | $16.43 |
| └ CloudWatch logs (EKS control plane, VPC flow logs) ★ | 70 | GB | $35.00 |
| **module.secondary (us-west-2, warm)** | | | |
| └ EKS cluster | 730 | hours | $73.00 |
| └ system node group: 2 × m7g.large | 1,460 | hours | $119.14 |
| └ Karpenter nodes: 1 × m7g.xlarge ★ | 730 | hours | $119.14 |
| └ NAT gateways × 3 | 2,190 | hours | $98.55 |
| └ ALB | 730 | hours | $16.43 |
| └ CloudWatch logs ★ | 30 | GB | $15.00 |
| **module.aurora (Global Database, PostgreSQL 16)** | | | |
| └ primary: 2 × db.r7g.large | 1,460 | hours | $402.96 |
| └ secondary: 1 × db.r7g.large | 730 | hours | $201.48 |
| └ storage, both regions ★ | 400 | GB-month | $40.00 |
| └ I/O requests ★ | 300 | M requests | $60.00 |
| └ replicated write I/O to us-west-2 ★ | 100 | M requests | $20.00 |
| └ AWS Backup snapshots + cross-region copy ★ | 400 | GB-month | $20.00 |
| **module.waf** | | | |
| └ web ACL + 5 rules | 1 | ACL | $10.00 |
| └ requests ★ | 50 | M | $30.00 |
| **module.dns** | | | |
| └ hosted zone + 2 HTTPS health checks | | | $3.50 |
| **Other** | | | |
| └ KMS keys × 7 | 7 | keys | $7.00 |
| └ Secrets Manager: 3 secrets + replicas | 6 | secrets | $2.40 |
| └ state bucket, lock table, SNS | | | < $2.00 |
| **Total** | | | **≈ $1,985 / month** |

Where the money goes: Aurora ≈ 38%, compute (EKS + nodes) ≈ 43%, networking (NAT + ALB) ≈ 14%.

Levers, in the order I would pull them:

1. **Karpenter on spot** for stateless services (already allowed by the NodePool): about −$280/month.
2. **Graviton is already the default** (m7g/r7g, ~20% cheaper than x86).
3. **Aurora I/O-Optimized** once I/O is more than 25% of the Aurora bill.
4. **VPC endpoints** (S3, ECR, STS, Secrets Manager) cut NAT data processing; worth it above ~1.5 TB/month.
5. DR warm → pilot light (0 Karpenter nodes, Aurora secondary headless): −$320/month, but RTO goes from ~15 to ~30 min. That is a business decision, not an engineering one.

staging and dev (`terraform/envs/{dev,staging}`) are one region, one NAT gateway, and no database in Terraform yet: roughly $250/month each before workload nodes.
