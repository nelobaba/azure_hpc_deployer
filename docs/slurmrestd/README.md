# Slurm REST API (slurmrestd) — Job Submission Guide

This document explains how to **set up, configure, and submit jobs** to Slurm via the **REST API (`slurmrestd`)**.  
It covers installation on AlmaLinux and Ubuntu, authentication using JWT tokens, and testing job submission with real examples.

---

## 1. Overview

The **Slurm REST API** (`slurmrestd`) provides a modern, programmatic way to interact with your Slurm cluster.  
It allows job submission, node inspection, and status retrieval over HTTP in JSON format.

It is commonly used for:

- Integrating Slurm with web applications or automation tools.
- Submitting jobs remotely without SSH access.
- Enabling monitoring dashboards and APIs.

---

## 2. Accessing the Cluster (Azure CycleCloud)

Before configuring or using the Slurm REST API, you must confirm that your **CycleCloud cluster** and its associated resources are active and accessible.

Follow these steps:

---

### Step 1 — Open Azure Portal

1. Log in to the [Azure Portal](https://portal.azure.com/).
2. Navigate to **Resource groups**.
3. Select the **resource group** that was created for your CycleCloud cluster (e.g., `hpc_deployer`).

---

### Step 2 — Verify Resources

Ensure that the following resources exist inside the resource group:

| Resource Type               | Example Name         | Purpose                                |
| --------------------------- | -------------------- | -------------------------------------- |
| Virtual machine (scheduler) | `cluster1-scheduler` | Primary controller running `slurmctld` |

> The **scheduler VM** (e.g., `cluster1-scheduler`) is automatically created by CycleCloud during cluster provisioning. It runs the Slurm controller and REST API components.  
> Tip: Depending on your CycleCloud template, the scheduler VM name may follow the pattern `<cluster-name>-scheduler` or `<cluster-name>-sched-0`.

---

### Step 3 — Connect to Scheduler VM via Bastion

1. In the Azure Portal, open the **scheduler VM** (e.g., `cluster1-scheduler`).
2. Click **Connect** → **Bastion**.
3. Enter:
   - **Username:** The same one used when you created the cluster (commonly `azureuser`).
   - **Authentication type:** _SSH Private Key_.
   - **Private Key:** Paste the contents of your private key (the `.pem` file you used to launch the cluster).
4. Click **Connect**.

You should now have a terminal session connected to your **scheduler node**.

---

### Step 4 — Verify Slurm Services

Once connected:

```bash
# Confirm you are connected as the right user
whoami

# Verify you are on the scheduler
hostname

# Check that slurmctld is running
systemctl status slurmctld

# Check munge service
systemctl status munge
```

> Note: The scheduler node typically runs only slurmctld and munge.
> The slurmd daemon runs on compute nodes and will be configured later.

Expected state:

```
● slurmctld.service - Slurm Controller Daemon
   Active: active (running)

● munge.service - MUNGE Authentication Service
   Active: active (running)
```

---

## 3. Verify the Operating System

Run this command to detect the current distribution:

```bash
cat /etc/os-release
```

Example outputs:

**AlmaLinux**

```
NAME="AlmaLinux"
VERSION="8.10 (Cerulean Leopard)"
```

**Ubuntu**

```
NAME="Ubuntu"
VERSION="22.04.5 LTS (Jammy Jellyfish)"
```

---

## 4. Installation Steps

The Slurm REST API (`slurmrestd`) is installed differently depending on your operating system.  
These steps cover **AlmaLinux / Rocky / RHEL** (CycleCloud default) and **Ubuntu / Debian**.

---

## AlmaLinux / Rocky / RHEL

1. **Check available Slurm packages**

   ```bash
   sudo dnf search slurm
   ```

   You should see entries like:

   ```
   slurm.x86_64          Slurm Workload Manager
   slurm-slurmrestd.x86_64  Slurm REST daemon
   ```

2. **Install Slurm and slurmrestd**

   ```bash
   sudo dnf install -y slurm slurm-slurmrestd
   ```

   > If unavailable, enable the **EPEL** or **OpenHPC** repository before retrying.

3. **Enable and start the REST service**

   ```bash
   sudo systemctl enable slurmrestd
   sudo systemctl start slurmrestd
   sudo systemctl status slurmrestd
   ```

   Example output:

   ```
   ● slurmrestd.service - Slurm REST daemon
      Loaded: loaded (/usr/lib/systemd/system/slurmrestd.service; enabled; vendor preset: disabled)
      Active: failed (Result: exit-code) since Tue 2025-11-11 20:09:00 UTC; 6s ago
     Process: 58150 ExecStart=/usr/sbin/slurmrestd $SLURMRESTD_OPTIONS (code=exited, status=217/USER)
   ```

   > **Don’t worry if the service fails here.**  
   > This is expected — the system user for `slurmrestd` isn’t properly configured yet.  
   > We’ll fix this in the next step when setting up authentication and service ownership.

---

## Ubuntu / Debian

1. **Update the package index**

   ```bash
   sudo apt update
   ```

2. **Search for available Slurm packages**

   ```bash
   apt search slurm
   ```

   Confirm that `slurmrestd` is listed.

3. **Install Slurm with REST API support**

   ```bash
   sudo apt install -y slurm-wlm slurmrestd
   ```

4. **Verify installation**

   ```bash
   which slurmrestd
   slurmrestd --help
   ```

   You should see usage information confirming the binary is installed.

---

## 5. Set Up JSON Web Tokens (JWT) for Authentication

The Slurm REST API (`slurmrestd`) uses **JSON Web Tokens (JWT)** for secure authentication between the REST daemon, controller, and database daemon (`slurmdbd`, if used).  
This step covers how to enable and configure JWT authentication for your CycleCloud cluster.

---

## Step 1 — Confirm JWT Library Installation

First, verify that the JWT library is installed:

```bash
rpm -qa | grep -i libjwt
```

<!-- If no result appears, install the library using:

```bash
sudo dnf install -y libjwt libjwt-devel
``` -->

> Slurm uses **libjwt** to handle JSON Web Tokens. It must be installed for authentication to work.

---

## Step 2 — Locate the State Save Directory

We’ll store the JWT key inside the Slurm **StateSaveLocation** directory.  
To confirm this location, run:

```bash
scontrol show config | grep -i StateSaveLocation
```

Example output:

```
StateSaveLocation      = /sched/cluster1/spool/slurmctld
```

> This directory is automatically created by CycleCloud during Slurm controller setup.

---

## Step 3 — Generate a JWT Key

Once you know the path, create the JWT key file inside it.  
Use the example below (replace the path if yours is different):

```bash
sudo dd if=/dev/random of=/sched/cluster1/spool/slurmctld/jwt_hs256.key bs=32 count=1
sudo chown slurm:slurm /sched/cluster1/spool/slurmctld/jwt_hs256.key
sudo chmod 0600 /sched/cluster1/spool/slurmctld/jwt_hs256.key
sudo chown slurm:slurm /sched/cluster1/spool/slurmctld
sudo chmod 0755 /sched/cluster1/spool/slurmctld
```

> The key file should be owned by the **SlurmUser** (usually `slurm`) or `root`, and must **not** be accessible by others.  
> Recommended permissions are `0400` or `0600`.

---

## Step 4 — Edit Slurm Configuration Files

Next, edit the Slurm configuration file (`/etc/slurm/slurm.conf`) to enable JWT authentication.

Before opening, install a text editor if not already available:

```bash
sudo dnf install -y nano
```

Then open the config:

```bash
sudo nano /etc/slurm/slurm.conf
```

Add or modify these lines:

```
AuthAltTypes=auth/jwt
AuthAltParameters=jwt_key=/sched/cluster1/spool/slurmctld/jwt_hs256.key
```

If you’re using **slurmdbd**, also open `/etc/slurm/slurmdbd.conf` and add the same lines.

---

## Step 5 — Restart Slurm Controller

Restart the controller to apply changes:

```bash
sudo systemctl restart slurmctld
sudo systemctl status slurmctld
```

You should see `Active: active (running)`.

---

## Step 6 — Create Tokens for Users

To generate JWT tokens for specific users (e.g., yourself):

```bash
scontrol token username=$USER
```

Example output:

```
Token (user=azureuser uid=1001) created
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

> You’ll use this token later when testing the REST API with `curl` or Postman.

---

<!-- ## 5. Configuration

1. Ensure `/etc/slurm/slurm.conf` exists and has a valid cluster name.

   ```bash
   grep ClusterName /etc/slurm/slurm.conf
   ```

2. Test manual startup:

   ```bash
   sudo -u slurmrestd    slurmrestd -a rest_auth/jwt -s openapi/slurmctld 127.0.0.1:6820
   ```

   > If you see errors about `tls/s2n`, either disable TLS or configure a valid certificate.

3. Persistent configuration:

   Edit `/etc/default/slurmrestd` or `/etc/sysconfig/slurmrestd`:

   ```bash
   SLURMRESTD_LISTEN="127.0.0.1:6820"
   SLURMRESTD_OPTIONS="-a rest_auth/jwt -s openapi/slurmctld"
   ```

   Then restart:

   ```bash
   sudo systemctl restart slurmrestd
   ```

--- -->

<!-- ## 6. Authentication (JWT)

1. Generate a daemon token:

   ```bash
   export SLURM_JWT=daemon
   ```

2. Generate a user token:

   ```bash
   scontrol token username=<your_username>
   export SLURM_JWT=<generated_token>
   ```

3. Test authentication:
   ```bash
   curl -H "X-SLURM-USER-TOKEN: $SLURM_JWT" http://127.0.0.1:6820/slurm/v0.0.41/ping
   ```

Expected output:

```json
{ "meta": { "plugin": "openapi/slurmctld" }, "ping": "pong" }
```

--- -->

<!-- ## 7. Submitting a Job via REST API

Create a job definition JSON file:

```json
{
  "script": "#!/bin/bash\nhostname\nsleep 5",
  "job": {
    "name": "hello_world_rest",
    "partition": "hpc",
    "time_limit": "00:02:00"
  }
}
```

Submit the job:

```bash
curl -X POST   -H "X-SLURM-USER-TOKEN: $SLURM_JWT"   -H "Content-Type: application/json"   -d @hello_job.json   http://127.0.0.1:6820/slurm/v0.0.41/job/submit
```

Expected output:

```json
{
  "job_id": 42,
  "job_submit_user": "azureuser",
  "job_name": "hello_world_rest"
}
```

Check the job:

```bash
squeue -j 42
```

---

## 8. Troubleshooting

| Error                                          | Cause                             | Fix                                                        |
| ---------------------------------------------- | --------------------------------- | ---------------------------------------------------------- |
| `I/O error writing script/environment to file` | Bad or unwritable spool directory | Check `SlurmdSpoolDir` permissions                         |
| `cannot find tls plugin for tls/s2n`           | TLS plugin not built or missing   | Install OpenSSL dev libs or disable TLS                    |
| `JobState=FAILED Reason=RaisedSignal:53`       | Node unreachable                  | Check node connectivity and state                          |
| `Slurm accounting storage is disabled`         | No accounting configured          | Enable `AccountingStorageType=accounting_storage/slurmdbd` |

---

## 9. Verifying API Endpoints

List available endpoints:

```bash
curl -H "X-SLURM-USER-TOKEN: $SLURM_JWT" http://127.0.0.1:6820/openapi/v0.0.41
```

Query nodes:

```bash
curl -H "X-SLURM-USER-TOKEN: $SLURM_JWT" http://127.0.0.1:6820/slurm/v0.0.41/nodes
```

Query partitions:

```bash
curl -H "X-SLURM-USER-TOKEN: $SLURM_JWT" http://127.0.0.1:6820/slurm/v0.0.41/partitions
```

---

## 10. Optional — Reverse Proxy

If exposing to external systems, run `slurmrestd` behind HTTPS via NGINX or Apache.

Example NGINX block:

```nginx
location /slurm/ {
    proxy_pass http://127.0.0.1:6820/;
    proxy_set_header X-SLURM-USER-TOKEN $http_authorization;
}
```

---

## References & Further Reading

- [Slurm REST API Documentation](https://slurm.schedmd.com/rest_api.html)
- [Slurmrestd Manual](https://slurm.schedmd.com/slurmrestd.html)
- [Slurm Configuration Guide](https://slurm.schedmd.com/slurm.conf.html)
- [JWT Authentication Docs](https://slurm.schedmd.com/jwt.html)
- [Slurm REST Source Code (GitHub)](https://github.com/SchedMD/slurm/tree/master/src/plugins/rest)
- [OpenHPC Documentation](https://openhpc.community/documentation/)

---

## Summary

| Component                 | Purpose                    |
| ------------------------- | -------------------------- |
| `slurmrestd`              | REST API service for Slurm |
| `rest_auth/jwt`           | Authentication plugin      |
| `/etc/default/slurmrestd` | Environment config         |
| `curl`                    | Submit and test jobs       |
| `scontrol`, `squeue`      | Native CLI validation      |

---

**Author:** Jonathan A. Martins
**Cluster:** `cluster1`
**Last Updated:** November 2025
**File:** `docs/slurmrestd/README.md` -->
