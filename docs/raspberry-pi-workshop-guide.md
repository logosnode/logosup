# Setting Up Your Logos Node — Workshop Guide

## Logos Circle Lisbon · [Date placeholder]

Welcome! By the end of this guide you will have a Logos Blockchain node running on a Raspberry Pi, contributing to a decentralised, censorship-resistant network. No prior Linux experience is required — just follow each step in order.

---

## What you'll need

### Hardware

| Item | Notes |
|------|-------|
| Raspberry Pi 4 (2 GB RAM or more) | Recommended. Pi 5 also works. Pi 3B+ may work but is not officially tested. |
| MicroSD card — **32 GB or larger** (Class 10 / A1 rated) | Faster cards mean faster initial setup. |
| Official Raspberry Pi USB-C power supply (5V / 3A) | A phone charger that under-delivers power will cause random crashes. |
| Ethernet cable | Wired connection is strongly preferred over Wi-Fi for a node. |
| Another computer (Windows, Mac, or Linux) | Used to flash the SD card and connect via SSH. |
| *(Optional)* USB keyboard + HDMI monitor | Useful for first-time troubleshooting if SSH does not work. |

### Software (on your other computer)

| Tool | Where to get it |
|------|----------------|
| **Raspberry Pi Imager** | https://www.raspberrypi.com/software/ |
| **SSH client** | Built into macOS/Linux terminal; Windows: use the built-in OpenSSH or [PuTTY](https://www.putty.org/) |

---

## Step 1: Flash the OS

> **What this does:** Writes the Raspberry Pi operating system onto the SD card so the Pi can boot.

1. Insert your SD card into your computer.
2. Open **Raspberry Pi Imager**.
3. Click **Choose Device** → select **Raspberry Pi 4** (or your model).
4. Click **Choose OS** → **Raspberry Pi OS (other)** → **Raspberry Pi OS Lite (64-bit)**.
   - "Lite" means no desktop — that is what we want for a headless server.
5. Click **Choose Storage** → select your SD card.
6. Click the **gear icon** (or press `Ctrl+Shift+X`) to open **Advanced settings**:
   - Check **Enable SSH** → select **Use password authentication**.
   - Set a **hostname** (e.g., `logosnode`).
   - Set a **username** (e.g., `pi`) and a strong **password** — write this down.
   - *(Optional)* Configure your Wi-Fi credentials if you are not using ethernet.
7. Click **Save**, then **Write**. Confirm when prompted.

> **📸 Screenshot placeholder:** *Raspberry Pi Imager — Advanced settings screen showing SSH enabled.*

> **⚠️ Note:** Writing will erase everything on the SD card. Make sure you have the right drive selected.

---

## Step 2: First boot and SSH in

> **What this does:** Powers on the Pi and gives you a terminal window into it from your computer.

1. Insert the flashed SD card into the Raspberry Pi.
2. Connect the ethernet cable from the Pi to your router.
3. Connect the power supply — the Pi will boot automatically (no power button).
4. Wait about 60–90 seconds for the first boot to complete.
5. Find the Pi's IP address — pick one of these methods:
   - Log into your **router admin page** (usually `192.168.1.1` or `192.168.0.1`) and look at connected devices. Find the entry named `logosnode`.
   - Or run this command on your computer (macOS/Linux):
     ```bash
     nmap -sn 192.168.1.0/24
     ```
     *(Replace `192.168.1.0/24` with your network range if different.)*
6. Once you have the IP (e.g., `192.168.1.42`), open a terminal and SSH in:
   ```bash
   ssh pi@192.168.1.42
   ```
   Enter the password you set in Step 1 when prompted.

> **📸 Screenshot placeholder:** *Terminal window showing a successful SSH login to the Pi.*

> **💡 Tip:** On Windows, open PowerShell or Command Prompt and type the same `ssh pi@<IP>` command. OpenSSH is included in Windows 10/11 by default.

---

## Step 3: Update the system

> **What this does:** Downloads and installs the latest security patches and software updates for the operating system. This is good practice before installing anything new.

Run the following two commands one after the other:

```bash
sudo apt update && sudo apt upgrade -y
```

This may take a few minutes. You will see a lot of text scrolling — that is normal. When it finishes you will see the command prompt again.

> **💡 Tip:** `sudo` means "run as administrator." On a freshly flashed Pi you will need it for system-level commands.

---

## Step 4: Install Docker

> **What this does:** Installs Docker, the software that packages and runs the Logos node in an isolated container. This is the officially recommended way to run a Logos node.

Run the official Docker install script:

```bash
curl -fsSL https://get.docker.com | sh
```

After the script finishes, add your user to the `docker` group so you can run Docker commands without `sudo`:

```bash
sudo usermod -aG docker $USER
```

Then **log out and log back in** so the group change takes effect:

```bash
exit
```

SSH back in again:

```bash
ssh pi@192.168.1.42
```

Verify Docker is working:

```bash
docker run hello-world
```

You should see a message saying **"Hello from Docker!"**.

> **🔗 Reference:** Docker documentation — https://docs.docker.com/engine/install/debian/

---

## Step 5: Install logosup

> **What this does:** Downloads the `logosup` tool, which automates everything needed to set up and run a Logos node — downloading the node software, generating your wallet keys, and starting the node.

Run the installer:

```bash
curl -sL https://raw.githubusercontent.com/logosnode/logosup/main/install.sh | bash
```

This downloads the `logosup` CLI and makes it available as a command. When it finishes, run the full node setup:

```bash
logosup install
```

The installer will:
1. Download the latest Logos Blockchain release and ZK circuits (this may take several minutes)
2. Build the Docker image
3. Generate your **wallet keys** — these are unique cryptographic keys for your node
4. Detect your public IP address
5. Optionally set up security hardening (recommended — press `y` when asked)
6. Optionally set up monitoring with Grafana dashboards (optional for beginners — you can skip with `n`)
7. Start your node

> **⚠️ Note:** When the installer displays your **wallet keys**, write them down or copy them somewhere safe immediately. These keys are how your node participates in the network and holds any tokens. If you lose them, you cannot recover them.

> **📸 Screenshot placeholder:** *Terminal showing `logosup install` completing and displaying wallet keys.*

---

## Step 6: Verify your node is running

> **What this does:** Confirms that your node has started and is connecting to the Logos network.

Check the node status:

```bash
logosup status
```

You should see output including:
- **Consensus mode**: starts as `Bootstrapping`, changes to `Online` after syncing with peers
- **Peer count**: number of other nodes your node is connected to
- **Wallet balances** for your keys

To see the live logs:

```bash
logosup logs -f
```

Press `Ctrl+C` to stop following the logs.

> **💡 Tip:** It is normal for the node to show `Bootstrapping` for the first 10–30 minutes while it finds peers and syncs. Check the [testnet dashboard](https://testnet.blockchain.logos.co/web/) to see the overall network state.

---

## Step 7: Port forwarding (if needed)

> **What this does:** Allows other nodes on the internet to connect to your node directly, making the network stronger.

The Logos node uses **port 3000/UDP** for peer-to-peer connections. If your Pi is behind a home router (which it almost certainly is), you may need to tell your router to forward this port to the Pi.

Steps vary by router brand. In general:

1. Log into your router admin page (usually `192.168.1.1`)
2. Find **Port Forwarding** (sometimes under "Advanced" or "NAT")
3. Create a new rule:
   - **Protocol**: UDP
   - **External port**: 3000
   - **Internal IP**: your Pi's IP address (e.g., `192.168.1.42`)
   - **Internal port**: 3000
4. Save and apply

> **🔗 Reference:** Generic port forwarding guide — https://portforward.com/

> **💡 Tip:** If you are not sure whether port forwarding is needed, check `logosup status` after your node has been running for 30+ minutes. If peer count is greater than 0, you are already connected to the network.

---

## Step 8: Back up your node

> **What this does:** Saves a copy of your wallet keys and configuration so you can restore your node if the SD card fails or if you move to a new Pi.

### What to back up

The most important files are in `~/.logos-node/` on the Pi:

| File/Directory | Why it matters |
|----------------|---------------|
| `~/.logos-node/user_config.yaml` | Your node configuration including generated keys |
| `~/.logos-node/data/` | Node state (RocksDB) — large, but good to back up periodically |

### How to back up

From your computer (not the Pi), run:

```bash
scp pi@192.168.1.42:~/.logos-node/user_config.yaml ./logos-node-config-backup.yaml
```

To back up the full data directory:

```bash
scp -r pi@192.168.1.42:~/.logos-node/data/ ./logos-node-data-backup/
```

> **💡 Tip:** You can also copy files to a USB drive plugged into the Pi, using `cp ~/.logos-node/user_config.yaml /media/usb/logos-node-config-backup.yaml` (mount path may vary).

### How often to back up

- **`user_config.yaml`**: Back up immediately after install and any time you change configuration. This file rarely changes.
- **`data/` directory**: Weekly or before any software update is a good habit.

> **📸 Screenshot placeholder:** *Terminal showing `scp` command completing successfully.*

---

## Troubleshooting

### The Pi won't boot / I can't SSH in

- Make sure the power supply is the official Raspberry Pi one. Under-powered supplies are the most common cause of boot failures.
- Check that the SD card is fully inserted.
- Try connecting a monitor and keyboard to see if there are any error messages on screen.
- Re-flash the SD card — sometimes a write error during flashing causes issues.

### `logosup` command not found after install

The install script adds `logosup` to your PATH, but this only takes effect in new shell sessions. Try:

```bash
source ~/.bashrc
```

Or log out and back in via SSH.

### Node stays in "Bootstrapping" mode for a long time

- Check that your internet connection is working: `ping google.com`
- Check that Docker is running: `docker ps`
- Check port forwarding (Step 7) — your node may not be reachable by peers
- Try restarting the node: `logosup stop && logosup start`

### Node was running but stopped after a Pi reboot

The node is configured with `restart: unless-stopped`, so it should start automatically on reboot. If it did not:

```bash
logosup start
```

If that fails, check the logs for errors:

```bash
logosup logs --tail=50
```

---

## Resources

| Resource | Link |
|----------|------|
| logosup GitHub | https://github.com/logosnode/logosup |
| Logos project website | https://logos.co/ |
| Logos Blockchain quickstart guide | https://github.com/logos-co/logos-docs/blob/main/docs/blockchain/quickstart-guide-for-the-logos-blockchain-node.md |
| Testnet faucet | https://testnet.blockchain.logos.co/web/faucet/ |
| Testnet dashboard | https://testnet.blockchain.logos.co/web/ |
| Raspberry Pi documentation | https://www.raspberrypi.com/documentation/ |
| Docker documentation | https://docs.docker.com/ |
| Logos Circle Lisbon | *[Contact placeholder — add your group link or email here]* |

---

*Guide prepared for Logos Circle Lisbon workshop participants. Contributions and corrections welcome — open an issue or pull request on the repository.*
