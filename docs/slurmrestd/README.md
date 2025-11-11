# Slurm REST API (slurmrestd) — Job Submission Guide

This document explains how to **set up, configure, and submit jobs** to Slurm via the **REST API (`slurmrestd`)**.  
It covers installation on AlmaLinux and Ubuntu, authentication using JWT tokens, and testing job submission with real examples.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Accessing the Cluster (Azure CycleCloud)](#2-accessing-the-cluster-azure-cyclecloud)
3. [Verify the Operating System](#3-verify-the-operating-system)
4. [Installation Steps](#4-installation-steps)
5. [Set Up JSON Web Tokens (JWT) for Authentication](#5-set-up-json-web-tokens-jwt-for-authentication)
6. [Configure and Run slurmrestd (Systemd Setup)](#6-configure-and-run-slurmrestd-systemd-setup)
7. [Submit a Test Job via Slurm REST API](#7-submit-a-test-job-via-slurm-rest-api)
8. [References & Further Reading](#references--further-reading)

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

Before configuring or using the Slurm REST API, confirm that your **CycleCloud cluster** and its associated resources are active and accessible.

<details>
<summary>Expand to view full setup steps</summary>

### Step 1 — Open Azure Portal

1. Log in to the [Azure Portal](https://portal.azure.com/).
2. Navigate to **Resource groups**.
3. Select the **resource group** created for your CycleCloud cluster (e.g., `hpc_deployer`).

---

### Step 2 — Verify Resources

Ensure that the following resources exist inside the resource group:

| Resource Type               | Example Name         | Purpose                                |
| --------------------------- | -------------------- | -------------------------------------- |
| Virtual machine (scheduler) | `cluster1-scheduler` | Primary controller running `slurmctld` |

> The **scheduler VM** (e.g., `cluster1-scheduler`) is automatically created by CycleCloud during cluster provisioning.  
> It runs the Slurm controller and REST API components.

---

### Step 3 — Connect to Scheduler VM via Bastion

1. Open the **scheduler VM** (e.g., `cluster1-scheduler`) in the Azure Portal.
2. Click **Connect → Bastion**.
3. Enter:
   - **Username:** Commonly `azureuser`
   - **Authentication:** _SSH Private Key_
   - **Private Key:** Paste your `.pem` key
4. Click **Connect**.

Once connected, verify Slurm:

```bash
whoami
hostname
systemctl status slurmctld
systemctl status munge
```

Expected output:

```
● slurmctld.service - Slurm Controller Daemon
   Active: active (running)

● munge.service - MUNGE Authentication Service
   Active: active (running)
```

</details>

---

## 3. Verify the Operating System

```bash
cat /etc/os-release
```

**AlmaLinux Example**

```
NAME="AlmaLinux"
VERSION="8.10 (Cerulean Leopard)"
```

**Ubuntu Example**

```
NAME="Ubuntu"
VERSION="22.04.5 LTS (Jammy Jellyfish)"
```

---

## 4. Installation Steps

<details>
<summary>Installation on AlmaLinux / Rocky / RHEL</summary>

### AlmaLinux / Rocky / RHEL

```bash
sudo dnf search slurm
sudo dnf install -y slurm slurm-slurmrestd
sudo systemctl enable slurmrestd
sudo systemctl start slurmrestd
sudo systemctl status slurmrestd
```

If the service fails with `status=217/USER`, don’t worry — it will be fixed later when we assign a system user.

</details>

<details>
<summary>Installation on Ubuntu / Debian</summary>

### Ubuntu / Debian

```bash
sudo apt update
apt search slurm
sudo apt install -y slurm slurm-slurmrestd
which slurmrestd
slurmrestd --help
```

</details>

---

## 5. Set Up JSON Web Tokens (JWT) for Authentication

Slurm REST API uses **JWT** for secure communication between components.

<details>
<summary>View JWT Setup Steps</summary>

### Step 1 — Confirm JWT Library

AlmaLinux

```bash
rpm -qa | grep -i libjwt
```

For Ubuntu:

```bash
dpkg -l | grep -i libjwt
```

### Step 2 — Locate StateSaveLocation

```bash
scontrol show config | grep -i StateSaveLocation
```

Output example:

```
StateSaveLocation = /sched/cluster1/spool/slurmctld
```

### Step 3 — Generate JWT Key

```bash
sudo dd if=/dev/random of=/sched/cluster1/spool/slurmctld/jwt_hs256.key bs=32 count=1
sudo chown slurm:slurm /sched/cluster1/spool/slurmctld/jwt_hs256.key
sudo chmod 0600 /sched/cluster1/spool/slurmctld/jwt_hs256.key
sudo chown slurm:slurm /sched/cluster1/spool/slurmctld
sudo chmod 0755 /sched/cluster1/spool/slurmctld
```

### Step 4 — Edit Slurm Configs

Install nano if not present:

```bash
sudo dnf install -y nano
sudo nano /etc/slurm/slurm.conf
```

Add:

```
AuthAltTypes=auth/jwt
AuthAltParameters=jwt_key=/sched/cluster1/spool/slurmctld/jwt_hs256.key
```

Restart:

```bash
sudo systemctl restart slurmctld
```

</details>

---

## 6. Configure and Run slurmrestd (Systemd Setup)

<details>
<summary>Expand Systemd Setup Instructions</summary>

### Step 1 — Create Dedicated Service User

```bash
sudo useradd -M -r -s /usr/sbin/nologin -U slurmrestd
```

### Step 2 — Override Systemd Configuration

```bash
sudo systemctl edit slurmrestd
```

Add:

```ini
[Service]
User=slurmrestd
Group=slurmrestd
Environment=SLURMRESTD_LISTEN=127.0.0.1:6820
```

### Step 3 — Create Runtime Options

```bash
sudo bash -c 'cat > /etc/sysconfig/slurmrestd << "EOF"
SLURMRESTD_OPTIONS="-a rest_auth/jwt -s openapi/slurmctld 127.0.0.1:6820"
EOF'
```

### Step 4 — Reload & Start

```bash
sudo systemctl daemon-reload
sudo systemctl restart slurmrestd
sudo systemctl status slurmrestd
```

If `Active: running`, your REST API is live.

</details>

---

## 6. Test the REST Endpoint

<details>
<summary>Expand API Testing Instructions</summary>

### Step 1 — Find Supported API Versions

```bash
slurmrestd -d list
```

### Step 2 — Get JWT Token

```bash
unset SLURM_JWT
export $(scontrol token username=$USER)
```

### Step 3 — Test Diagnostic Endpoint

```bash
API_VERSION=v0.0.42
curl -s -o "/tmp/curl.log" -k -vvvv   -H X-SLURM-USER-TOKEN:$SLURM_JWT   -X GET "http://127.0.0.1:6820/slurm/${API_VERSION}/diag"
```

Expected output:

```json
{ "meta": { "plugin": "openapi/slurmctld" }, "ping": "pong" }
```

</details>

---

## 7. Submit a Test Job via Slurm REST API

<details open>
<summary>View Complete Job Submission Guide</summary>

### Step 1 — Create Job Definition

```bash
cat > hello_rest.json << 'EOF'
{
  "job": {
    "name": "hello_world_rest",
    "partition": "hpc",
    "time_limit": 60,
    "current_working_directory": "/shared/home/azureuser",
    "standard_output": "hello_world_rest.%j.out",
    "standard_error": "hello_world_rest.%j.err",
    "environment": [
      "HOME=/shared/home/azureuser",
      "PATH=/usr/local/bin:/usr/bin:/bin",
      "LANG=en_US.UTF-8"
    ],
    "script": "#!/bin/bash\necho \"Hello from Slurm REST\"\nhostname\nwhoami\npwd\nsleep 10\necho \"Done.\"\n"
  }
}
EOF
```

### Step 2 — Submit Job

```bash
curl -s -k   -H "X-SLURM-USER-TOKEN: $SLURM_JWT"   -H "Content-Type: application/json"   -X POST   -d @hello_rest.json   "http://127.0.0.1:6820/slurm/${API_VERSION}/job/submit"
```

Expected:

```json
{
  "job_id": 123,
  "job_submit_user": "azureuser",
  "job_name": "hello_world_rest"
}
```

### Step 3 — Verify Job

```bash
squeue -j 123
```

or, if accounting is enabled:

```bash
sacct -j 123 -o JobID,JobName,Partition,State,ExitCode
```

### Step 4 — Check Output

```bash
cat hello_world_rest.123.out
```

Expected:

```
Hello from Slurm REST
cluster1-hpc-1
azureuser
/shared/home/azureuser
Done.
```

</details>

---

## References & Further Reading

- [Slurm REST API Documentation](https://slurm.schedmd.com/rest_api.html)
- [Slurmrestd Manual](https://slurm.schedmd.com/slurmrestd.html)
- [Slurm Configuration Guide](https://slurm.schedmd.com/slurm.conf.html)
- [JWT Authentication Docs](https://slurm.schedmd.com/jwt.html)
- [Slurm REST Source Code (GitHub)](https://github.com/SchedMD/slurm/tree/master/src/plugins/rest)
- [OpenHPC Documentation](https://openhpc.community/documentation/)
