# Setting Up Your Logos Node — Workshop Guide

## Logos Circle Lisbon · June 10, 2026

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
6. Click the **⚙️ gear icon** (or press `Ctrl+Shift+X`) to open **Advanced Options**:
   - Set a **hostname** — use `logos-node` (this is the name your Pi will advertise on the network).
   - Check **Enable SSH** → select **Use password authentication**.
   - Set a **username** (e.g., `pi`) and a strong **password** — write this down.
   - Enter your **WiFi SSID and password** for the workshop network.
   - Set your **locale and timezone** (e.g., `Europe/Lisbon`).
7. Click **Save**, then **Write**. Confirm when prompted.

The Advanced Options screen should show SSH toggled on, your chosen hostname (e.g. `logos-node`), and the WiFi credentials filled in before you proceed.

> **⚠️ Note:** Writing will erase everything on the SD card. Make sure you have the right drive selected.

### Adding a second WiFi network (home + workshop)

Raspberry Pi Imager only lets you enter one WiFi network. If you want the Pi to also connect to your home network automatically when you bring it back, you can add it by editing the SD card directly after flashing.

**The file to edit:** `wpa_supplicant.conf` on the `boot` partition of the SD card.

- **Windows**: the `boot` partition appears as a drive in File Explorer (e.g., `D:\`).
- **Mac**: it mounts in Finder automatically (look for `boot` on the desktop or in the sidebar).
- **Linux**: it mounts automatically at `/media/<user>/boot` or similar.

Open `wpa_supplicant.conf` in any text editor and replace its contents with:

```
country=PT
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="WorkshopWiFi"
    psk="workshoppassword"
    priority=1
}

network={
    ssid="HomeWiFi"
    psk="homepassword"
    priority=2
}
```

Replace `WorkshopWiFi` / `workshoppassword` and `HomeWiFi` / `homepassword` with your actual credentials. **Higher priority number = tried first**, so setting home WiFi to `priority=2` means the Pi will connect home when it is back from the workshop.

> **💡 Tip:** If you already set a WiFi in Imager's Advanced Options, you will see a `network={...}` block already in the file. You can add a second `network={...}` block below it — the Pi will try both.

---

## Step 2: First boot and SSH in

> **What this does:** Powers on the Pi and gives you a terminal window into it from your computer.

1. Insert the flashed SD card into the Raspberry Pi.
2. Connect the ethernet cable from the Pi to your router.
3. Connect the power supply — the Pi will boot automatically (no power button).
4. Wait about 60–90 seconds for the first boot to complete.
5. Find the Pi's IP address — pick one of these methods:
   - Log into your **router admin page** (usually `192.168.1.1` or `192.168.0.1`) and look at connected devices. Find the entry named `logos-node`.
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

On a successful login you'll see a Raspberry Pi OS welcome banner followed by a prompt like `pi@logos-node:~ $`.

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

## Step 4: Install logosup

> **What this does:** Downloads the `logosup` tool, which automates everything needed to set up and run a Logos node — including Docker setup, downloading the node software, generating your wallet keys, and starting the node.

> **Note on Docker:** `logosup` handles Docker automatically — you don't need to install it separately. If you prefer to set everything up manually (recommended for production/mainnet), follow the [official CLI guide](https://github.com/logos-co/logos-docs/blob/main/docs/blockchain/get-started/run-a-logos-blockchain-node-from-cli.md). For this workshop we'll use `logosup` which automates the entire Docker setup.

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

Once the installer finishes, the terminal will print your wallet public key and private key. Copy these to a safe location before continuing — they will not be shown again.

---

## Step 5: Verify your node is running

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

## Step 6: Port forwarding (optional — for better connectivity)

> **What this does:** Allows other nodes on the internet to connect to your node directly, which improves peer discovery and makes the network stronger.

**Port forwarding is not strictly required for the workshop.** Your node can connect outbound to bootstrap peers and participate in the testnet without it. If your peer count stays at 0 after 30 minutes, it is worth trying.

The Logos node uses **port 3000/UDP** for peer-to-peer connections. If your Pi is behind a home router (which it almost certainly is), forwarding this port lets other nodes reach yours directly.

> **💡 Check UPnP first:** Many modern routers support UPnP (Universal Plug and Play), which can handle port forwarding automatically without any manual steps. Log into your router admin page and look for a UPnP setting — if it is enabled, port forwarding may already be working.

If you need to set it up manually, the general steps are:

1. Log into your router admin page (usually `192.168.1.1`)
2. Find **Port Forwarding** (sometimes under "Advanced" or "NAT")
3. Create a new rule:
   - **Protocol**: UDP
   - **External port**: 3000
   - **Internal IP**: your Pi's IP address (e.g., `192.168.1.42`)
   - **Internal port**: 3000
4. Save and apply

> **🔗 Reference:** Generic port forwarding guide — https://www.wikihow.com/Set-Up-Port-Forwarding-on-a-Router

> **💡 Tip:** Run `logosup status` after your node has been running for 30+ minutes. If peer count is greater than 0, you are already connected to the network and port forwarding is working or not needed.

---

## Step 7: Back up your node

> **What this does:** Saves a copy of your wallet keys so you can restore your node if the SD card fails or if you move to a new Pi.

Run this command on the Pi:

```bash
logosup keys backup
```

Output looks like:

```
✔ Wallet keys backed up to logos-node-keys.backup.yaml
```

Then display the backup file:

```bash
cat logos-node-keys.backup.yaml
```

Copy the output and save it somewhere safe — a password manager, a printed piece of paper, or an encrypted note. That is all you need for the workshop.

> **⚠️ Important:** These keys cannot be recovered if lost. Back them up before leaving the workshop.

### Advanced: Keeping your node secure on Mainnet

For Mainnet, keep your `logos-node-keys.backup.yaml` file extra secure — store it in a password manager, encrypted storage, or printed and locked away. If you want to also copy the full data directory off the Pi:

```bash
scp -r pi@logos-node.local:/home/pi/.logos ~/logos-backup
```

---

## Next Steps — Useful Commands

**Node status:**
```bash
logosup status
```
Shows whether your node is running, current block height, and how many peers you're connected to. Run this any time you want to check your node is healthy.

**Wallet — check balance:**
```bash
logosup wallet balance
```
Shows your wallet address and current balance.

**Wallet — send a transfer:**
```bash
logosup wallet transfer
```
Walks you through sending tokens to another address. Follow the interactive prompts.

**View logs (live):**
```bash
logosup logs
```
Shows the live output from your node. Press `Ctrl+C` to stop watching. Useful for troubleshooting.

**Stop / start / restart:**
```bash
logosup stop
logosup start
logosup restart
```

**Grafana monitoring dashboard:**

If you enabled monitoring during install, open this in your browser to see charts of your node's performance, block sync progress, and peer connections:

```
https://localhost:3001
```

Or from another device on the same network: `https://logos-node.local:3001`. Your browser will show a security warning on first visit — accept it to proceed (it's a self-signed certificate generated locally).

**Update the node:**
```bash
logosup update
```
Downloads and applies the latest version. Run this periodically to stay in sync.

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
- Check port forwarding (Step 6) — your node may not be reachable by peers
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
| Logos Blockchain quickstart guide | https://github.com/logos-co/logos-docs/blob/main/docs/blockchain/get-started/run-a-logos-blockchain-node-from-cli.md |
| Testnet faucet | https://testnet.blockchain.logos.co/web/faucet/ |
| Testnet dashboard | https://testnet.blockchain.logos.co/web/ |
| Raspberry Pi documentation | https://www.raspberrypi.com/documentation/ |
| Docker documentation | https://docs.docker.com/ |
| Port forwarding guide | https://www.wikihow.com/Set-Up-Port-Forwarding-on-a-Router |
| Logos Circle Lisbon | *[Contact placeholder — add your group link or email here]* |

---

*Guide prepared for Logos Circle Lisbon workshop participants. Contributions and corrections welcome — open an issue or pull request on the repository.*
