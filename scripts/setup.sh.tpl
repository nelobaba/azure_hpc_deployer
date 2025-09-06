#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.


# --- Update package lists and install core prerequisites ---
echo "--> Updating package lists and installing core prerequisites..."
sudo apt update
sudo apt install -y net-tools gnupg unzip python3-venv

# --- Add Microsoft GPG key and Azure CycleCloud repository ---
echo "--> Adding Microsoft GPG key and Azure CycleCloud repository..."
# NOTE: Using 'apt-key add' is deprecated. For production environments,
# it's recommended to use the new method for adding GPG keys:
# curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/microsoft.gpg
# echo "deb [arch=amd64 signed-by=/etc/apt/trusted.gpg.d/microsoft.gpg] https://packages.microsoft.com/repos/cyclecloud bionic main" | sudo tee /etc/apt/sources.list.d/cyclecloud.list > /dev/null
wget -qO - https://packages.microsoft.com/keys/microsoft.asc | sudo apt-key add -
echo "deb https://packages.microsoft.com/repos/cyclecloud bionic main" | sudo tee /etc/apt/sources.list.d/cyclecloud.list > /dev/null

# --- Install OpenJDK 8 ---
echo "--> Updating package lists again and installing OpenJDK 8..."
sudo apt update
sudo apt install -y openjdk-8-jdk
sudo update-alternatives --set java /usr/lib/jvm/java-8-openjdk-amd64/jre/bin/java

# --- Install Azure CLI ---
echo "--> Installing Azure CLI..."
sudo apt install -y azure-cli

# --- Install Azure CycleCloud Server ---
echo "--> Installing Azure CycleCloud Server version ${cyclecloud_version}..."
sudo apt install -yq cyclecloud8="${cyclecloud_version}"

# --- Wait for CycleCloud Server to start ---
echo "--> Waiting for CycleCloud Server to start..."
# This command typically requires root or the user owning the CycleCloud installation.
# Assuming it's runnable with sudo.
sudo /opt/cycle_server/cycle_server await_startup

# --- Install CycleCloud CLI ---
echo "--> Installing CycleCloud CLI..."
# Unzip the installer to a temporary directory
sudo unzip /opt/cycle_server/tools/cyclecloud-cli.zip -d /tmp
# Run the installer script. Using --system typically installs to /usr/local/bin
# which is in the system's PATH, making the 'cyclecloud' command globally available.
sudo python3 /tmp/cyclecloud-cli-installer/install.py -y --installdir /usr/local/bin --system

# --- Initialize CycleCloud UI ---
echo "--> Initializing CycleCloud UI..."

# Use the installed cyclecloud CLI to initialize the UI
cp /usr/loca;/bin/cycecloud /usr/bin/

echo "--> Go to the UI to create admin user, create subscription ---->  Azure CycleCloud setup script finished successfully."