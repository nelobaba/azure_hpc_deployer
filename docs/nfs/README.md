# NFS Setup Guide for Azure CycleCloud

This guide walks through creating, configuring, and cleaning up a private NFS server on Azure to be used with CycleCloud clusters.

---

## Part A: Create and Configure the Linux VM

1. **Create a Linux VM in the Azure Portal**

   - Log in to the **Azure Portal**.
   - Navigate to **Virtual machines** → **+ Create** → **Virtual machine**.
   - Use the same **Resource group** as your CycleCloud installation.
   - Enter a **VM name** (e.g., `nfs-server-vm`).
   - Choose an **Image** (Ubuntu Server 22.04 LTS recommended, or CentOS Stream 9).
   - For **Size**, select **Standard_D4s_v3** (4 vCPUs, suitable for NFS server workloads).
   - For **Administrator account**, select **SSH public key** authentication.
   - On the **Networking** tab, place the VM in the same **Virtual Network** as your CycleCloud cluster.
   - For **NIC network security group**, choose **Advanced** and allow **SSH (port 22)** for management only.
   - On the **Disks** tab, add a new **data disk**. Set **Host caching** to **Read/Write**.
   - Click **Review + create** → **Create**.

2. **Prepare your SSH key locally**

   - After downloading the private key (`nfs-server-vm-key.pem`) from Azure:
     ```bash
     mkdir -p ~/.ssh
     mv ~/Downloads/nfs-server-vm-key.pem ~/.ssh/
     chmod 700 ~/.ssh
     chmod 600 ~/.ssh/nfs-server-vm-key.pem
     ```
   - Test SSH access from your local terminal:
     ```bash
     ssh -i ~/.ssh/nfs-server-vm-key.pem azureuser@<nfs-vm-public-ip>
     ```
   - If your VM has **no public IP**, connect using **Azure Bastion** instead.

3. **Prepare and mount the data disk**

   Once you’re SSH’d into the VM:

   1. **Switch to root**

      ```bash
      sudo -i
      ```

      Running as root ensures you have full privileges to format, mount, and edit system files.

   2. **Format the new disk**

      ```bash
      mkfs.ext4 /dev/sdc
      ```

      - Creates an **ext4 filesystem** on `/dev/sdc`.
      - Run this only once for a new disk.

   3. **Create a mount point**

      ```bash
      mkdir -p /nfs/export
      ```

   4. **Mount the disk temporarily**
      ```bash
      mount /dev/sdc /nfs/export
      ```

   ### Make the mount persistent

   1. **Find the disk’s UUID**

      ```bash
      blkid
      ```

      Example output:

      ```
      /dev/sda1: UUID="e8fcb3f3-8a2e-43e4-a9c1-b09a0a37a42e" TYPE="ext4"
      /dev/sdc:  UUID="1234abcd-56ef-7890-1234-abcdef123456" TYPE="ext4"
      ```

   2. **Edit `/etc/fstab`**

      ```bash
      nano /etc/fstab
      ```

      Add:

      ```
      UUID=<your_uuid>   /nfs/export   ext4   defaults   0   0
      ```

      Example:

      ```
      UUID=1234abcd-56ef-7890-1234-abcdef123456   /nfs/export   ext4   defaults   0   0
      ```

   3. **Save and exit** (`CTRL+O`, `Enter`, `CTRL+X` in nano).

   4. **Test the entry**

      ```bash
      mount -a
      ```

   5. **Verify**

      ```bash
      df -h
      ```

   6. **Reboot to confirm**
      ```bash
      reboot
      ```
      After reconnecting, run `df -h` again to confirm `/nfs/export` mounts automatically.

---

## Part B: Install and Configure the NFS Server

1. **Install NFS packages**

   - On Ubuntu/Debian:
     ```bash
     sudo apt-get update
     sudo apt-get install -y nfs-kernel-server
     ```
   - On RHEL/CentOS:
     ```bash
     sudo dnf install -y nfs-utils
     ```

2. **Configure exports**

   - Edit `/etc/exports`:
     ```bash
     sudo nano /etc/exports
     ```
   - Add a line (replace subnet with your CycleCloud VNet CIDR, e.g., `10.0.1.0/24`):

     ```
     /nfs/export 10.0.1.0/24(rw,sync,no_subtree_check,no_root_squash)
     ```

   - Apply configuration:
     ```bash
     sudo exportfs -a
     ```

3. **Restart and enable NFS**
   ```bash
   sudo systemctl restart nfs-kernel-server
   sudo systemctl enable nfs-kernel-server
   ```

---

## Part C: Configure Azure Networking and Firewall

1. **Allow NFS traffic in the NSG**

   - In the Azure Portal → **NFS VM → Networking → Add inbound port rule**:
     - Source: `IP addresses`
     - Source CIDR: `10.0.1.0/24` (CycleCloud subnet)
     - Destination port ranges: `2049`
     - Protocol: `Any`
     - Action: `Allow`
     - Name: `Allow-NFS`

2. **Verify Linux firewall**

   - On Ubuntu:
     ```bash
     sudo ufw status
     sudo ufw allow from 10.0.1.0/24 to any port nfs
     ```
   - On CentOS:
     ```bash
     sudo firewall-cmd --add-service=nfs --permanent
     sudo firewall-cmd --reload
     ```

3. **Verify NFS service**
   ```bash
   sudo ss -tulpn | grep 2049
   sudo exportfs -v
   ```

---

## Part D: Mount the NFS Share on Clients

### 1. Mount via CycleCloud UI (External Mount)

If you’re mounting the share through the CycleCloud **cluster configuration UI**:

- Go to your cluster settings in the CycleCloud web UI.
- Under **File Systems**, choose to add an external mount.
- Provide the following values:
  - **Server** → `<nfs-vm-private-ip>`
  - **Export Path** → `/nfs/export`
- Save and apply the configuration.

CycleCloud will automatically mount the NFS share on all cluster nodes during provisioning.

---

## Part E: Cleanup

When done with testing or before tearing down resources:

1. **Unmount the NFS share on all clients**

   ```bash
   sudo umount /mnt/nfs
   ```

2. **Unmount on the NFS server**

   ```bash
   sudo umount /nfs/export
   ```

3. **Destroy resources**
   - If using Terraform, run your **destroy** workflow.
   - If provisioned manually, delete the NFS VM, disk, and NSG rules from the Azure Portal.

---

At this point you have a complete lifecycle:

- Create → Configure → Use → Cleanup for NFS on Azure.
