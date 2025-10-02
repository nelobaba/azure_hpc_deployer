# NFS Setup Guide for Azure CycleCloud

This guide walks through creating a Storage Account and an NFS File Share on Azure, then mounting it on your CycleCloud cluster VMs. Unlike managing a private NFS server VM, this uses Azure Files NFS directly with Private Endpoint integration.

---

## Part A: Create and Configure the Storage Account (with Private Endpoint)

1. In the Azure Portal, go to **Storage accounts** → **+ Create**.
2. Choose the same **Resource group** as your CycleCloud deployment.
3. Under **Basics**:
   - **Performance**: Premium
   - **Preferred storage type**: Azure File
   - **Provisioning model**: Provisioned v2 (capacity, throughput, and IOPS are configured individually)
   - **Redundancy**: LRS (Locally Redundant Storage) for basic setups
4. Under **Networking**:
   - Set **Public network access** to **Disabled**.
   - In the **Private endpoint** section, click **+ Add private endpoint**.
     - **Name**: enter a descriptive name (e.g., `nfs-pe`).
     - **Storage sub-resource**: select **file** from the dropdown.
     - **Virtual Network**: select the VNet where your CycleCloud cluster runs.
     - **Subnet**: choose the subnet where your cluster nodes are deployed.
     - **Private DNS integration**: select **Yes**. If a DNS zone (`privatelink.file.core.windows.net`) already exists, select it; otherwise, allow the wizard to create one.
5. Click **Review + create** → **Create** and wait for provisioning.
6. After the account is created, go to **Configuration** (in the left-hand menu) and set **Secure transfer required** to **Disabled**.

---

## Part B: Create an NFS File Share

1. Open the Storage Account you created.
2. Navigate to **File shares** → **+ File share**.
3. Enter a **Name** (e.g., `shared`).
4. Under **Protocol**, select **NFS**.
5. Set **Root squash**:
   - **No root squash** (recommended for CycleCloud): root users on the client VM retain root access on the share.
6. Click **Review + create** → **Create**.

---

After creation, verify from a CycleCloud VM that DNS resolves correctly:

```bash
getent hosts <storage-account>.file.core.windows.net
```

---

## Part C: Mount the NFS Share on a CycleCloud VM

### 1. Install NFS client utilities (if not already installed)

On Ubuntu/Debian:

```bash
sudo apt-get update
sudo apt-get install -y nfs-common
```

On CentOS/RHEL:

```bash
sudo dnf install -y nfs-utils
```

Reference: [Mount Azure Files NFS shares (Microsoft Docs)](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-how-to-mount-nfs-shares?tabs=Ubuntu)

---

### 3. Mount the NFS share using the classic NFS client

```bash
sudo mkdir -p /mount/<storage-account>/<share-name>
sudo mount -t nfs <storage-account>.file.core.windows.net:/<storage-account>/<share-name> /mount/<storage-account>/<share-name> -o vers=4,minorversion=1,sec=sys,nconnect=4
```

- Replace `<storage-account>` with your account name (e.g., `nfsstrgeacct`).
- Replace `<share-name>` with the file share name you created (e.g., `shared`).

---

### 4. Verify the mount

```bash
df -h
```

---

## Part D: Configure External NFS in CycleCloud

When creating or editing your CycleCloud cluster, add an **External NFS mount** under **File Systems** with the following values:

- **FS Type**: External NFS
- **IP Address**: `nfsstrgeacct.file.core.windows.net`
- **Mount Point**: `/mount/nfsstrgeacct/shared`
- **Export Path**: `/nfsstrgeacct/shared`
- **Mount Options**: `vers=4,minorversion=1,sec=sys,nconnect=4`

This ensures the NFS share is mounted automatically on all cluster nodes when the cluster is provisioned.

---

At this point, your Azure Files NFS share is integrated with your CycleCloud cluster VMs using Private Endpoint + persistent mount configuration.

---

## References & Further Reading

- Azure Files NFS: Security & Networking
  https://learn.microsoft.com/en-us/azure/storage/files/files-nfs-protocol#security-and-networking
- Azure Storage: NFS / Network File System protocol support  
  https://learn.microsoft.com/en-gb/azure/storage/blobs/network-file-system-protocol-support
- Troubleshoot Linux NFS for Azure Files  
  https://learn.microsoft.com/en-us/troubleshoot/azure/azure-storage/files/security/files-troubleshoot-linux-nfs?toc=%2Fazure%2Fstorage%2Ffiles%2Ftoc.json&tabs=Ubuntu
- Encryption in transit for Azure Files NFS shares  
  https://learn.microsoft.com/en-us/azure/storage/files/encryption-in-transit-for-nfs-shares?tabs=Ubuntu
- Mount NFS Azure file shares on Linux
  https://learn.microsoft.com/en-us/azure/storage/files/storage-files-how-to-mount-nfs-shares?tabs=Ubuntu
