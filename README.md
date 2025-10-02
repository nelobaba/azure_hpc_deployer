# azure_hpc_deployer

Infrastructure-as-Code (IaC) project for deploying an Azure CycleCloud–based HPC environment.  
Terraform is executed via a **manual, parameterized GitHub Actions workflow** (not on every push).

---

## Overview

- Terraform provisions:
  - Virtual Network (VNet) with multiple subnets (CycleCloud, Windows, Bastion).
  - Network Security Groups (NSGs) with rules for CycleCloud (8080) and Windows RDP (3389).
  - A **Linux VM** for Azure CycleCloud Server.
  - A **Windows VM** for accessing the CycleCloud web UI and linking the subscription.
  - An **Azure Bastion Host** for secure browser-based RDP/SSH into both VMs (no public IPs needed).
- CI/CD is **manual**: you trigger the workflow in GitHub and pass parameters (plan/apply/destroy, env, etc.).
- After deployment:
  1. Connect to the **CycleCloud VM** via Bastion and run the bootstrap commands (up to UI initialization).
  2. Log into the **Windows VM**, open the CycleCloud web UI at `http://<cyclecloud-private-ip>:8080`, create the admin account, and link the subscription.
  3. Return to the **CycleCloud VM** and run the one-line CLI initialize command.

---

## How to Run (CI/CD)

1. Go to **GitHub → Actions → _HPC Deploy_** (or your workflow name).
2. Click **Run workflow**, choose the branch and **parameters** (e.g., _plan_, _apply_, or _destroy_), then **Run**.
3. Wait for the workflow to complete. It will create the infrastructure in Azure.

> Note: Terraform is **not** run automatically on push. Always use the manual workflow dispatch with parameters.

---

## Connect to the CycleCloud VM

1. In the **Azure Portal**, open the **CycleCloud VM** resource.
2. Use **Bastion → Connect** to start a browser-based SSH session to the VM.
3. As the `azureuser`, paste and run the **bootstrap commands up to (but not including) the UI initialize step** from your `scripts/setup.sh.tpl`:
   - Run everything **until** the comment:
     ```
     # --- Initialize CycleCloud UI ---
     echo "--> Initializing CycleCloud UI..."
     ```
   - **Do not** run the `cyclecloud initialize ...` line yet.

This partial bootstrap installs prerequisites (Java, Azure CLI), the **CycleCloud server**, and the **CycleCloud CLI**, and waits for the service to come up.

---

## Finish Setup in the CycleCloud UI (Windows VM)

1. Log in to your **Windows VM** (or any machine with a browser joined to the VNet).
2. Open the CycleCloud web UI at:
   ```
   http://<cyclecloud-private-ip>:8080
   ```
   Where `<cyclecloud-private-ip>` is the **private IP of the CycleCloud VM** (see its Overview page).
3. In the UI:
   - Create the **admin account**.
   - Link your **Azure subscription** (per your org’s setup flow).

---

## Finalize via CLI on the CycleCloud VM

Return to the **CycleCloud VM** (Bastion SSH session) and run the one-time initialize command:

```bash
cyclecloud initialize --loglevel=debug --batch \
  --url=http://localhost:8080 --verify-ssl=false \
  --username="azureuser" --password="12345"
```

> Replace credentials as appropriate for your environment. In production, source from a secret store (Azure Key Vault / GitHub Actions Secrets) instead of hardcoding.

## Next: NFS Shared Storage (Optional)

You can extend this deployment with a dedicated NFS server for shared storage.  
See the detailed setup guide here: [docs/nfs/README.md](docs/nfs/README.md)
