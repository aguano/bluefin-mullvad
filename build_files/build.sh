#!/bin/bash
# =============================================================================
# build.sh – Anpassungen für das Image bluefin-mullvad.
# Läuft während des Container-Builds auf GitHub, NICHT auf dem Rechner.
# =============================================================================
set -ouex pipefail   # bei Fehlern sofort abbrechen, jeden Befehl ins Build-Log schreiben

# --- 0. Eigene Dateien aus system_files/ ins Image kopieren --------------------
# Aus der Vorlage übernommen: Alles im Ordner system_files/ des Repositorys
# landet an derselben Stelle im Image (z. B. system_files/etc/... → /etc/...).
cp -avf "/ctx/system_files"/. /

# =============================================================================
# Mullvad VPN (Dienst + grafische App + Killswitch)
# =============================================================================

# --- 1. /opt vorbereiten ------------------------------------------------------
# Im bootc-Image ist /opt ein Symlink auf /var/opt. /var wird aber nicht aus dem
# Image übernommen, und das Mullvad-RPM will nach "/opt/Mullvad VPN" entpacken.
# Deshalb ersetzen wir den Symlink kurzzeitig durch ein echtes Verzeichnis
# und merken uns das ursprüngliche Ziel.
OPT_LINK=""
if [[ -L /opt ]]; then
    OPT_LINK="$(readlink /opt)"
    rm /opt
    mkdir /opt
fi

# --- 2. Offizielle Mullvad-Paketquelle hinzufügen und Paket installieren ------
dnf5 config-manager addrepo --from-repofile=https://repository.mullvad.net/rpm/stable/mullvad.repo
dnf5 install -y mullvad-vpn

# --- 3. Grafische App aus /opt in den unveränderlichen Teil (/usr) verschieben -
mv "/opt/Mullvad VPN" "/usr/lib/Mullvad VPN"

# /opt wieder in den Originalzustand versetzen
if [[ -n "${OPT_LINK}" ]]; then
    rmdir /opt
    ln -s "${OPT_LINK}" /opt
fi

# Aufrufbar machen (die App-Starter-Datei zeigt gleich auf /usr/bin/mullvad-vpn)
ln -sf "/usr/lib/Mullvad VPN/mullvad-vpn" /usr/bin/mullvad-vpn
ln -sf "/usr/lib/Mullvad VPN/mullvad-gui" /usr/bin/mullvad-gui

# Electron-Sandbox der grafischen App braucht das setuid-Bit
chmod 4755 "/usr/lib/Mullvad VPN/chrome-sandbox"

# --- 4. Alte /opt-Pfade in Starter-Datei und Dienst-Units umschreiben ----------
sed -i 's|"/opt/Mullvad VPN/mullvad-vpn"|/usr/bin/mullvad-vpn|g' \
    /usr/share/applications/mullvad-vpn.desktop
for unit in /usr/lib/systemd/system/mullvad-daemon.service \
            /usr/lib/systemd/system/mullvad-early-boot-blocking.service; do
    sed -i 's|/opt/Mullvad\\x20VPN/|/usr/lib/Mullvad\\x20VPN/|g' "${unit}"   # systemd-Schreibweise für Leerzeichen
    sed -i 's|/opt/Mullvad VPN/|/usr/lib/Mullvad VPN/|g' "${unit}"          # normale Schreibweise
done

# Selbstkontrolle: Bricht den Build ab, falls irgendwo noch ein /opt-Pfad steht
if grep -q "/opt/Mullvad" /usr/share/applications/mullvad-vpn.desktop \
        /usr/lib/systemd/system/mullvad-*.service; then
    echo "FEHLER: Es sind noch /opt-Pfade übrig" >&2
    exit 1
fi

# --- 5. Dienste dauerhaft aktivieren ------------------------------------------
# mullvad-daemon = der eigentliche VPN-Dienst (enthält den Killswitch)
# mullvad-early-boot-blocking = sperrt das Netz beim Hochfahren, bis der Dienst läuft
systemctl enable mullvad-daemon.service
systemctl enable mullvad-early-boot-blocking.service

# --- 6. Paketquelle im fertigen System abschalten ------------------------------
# Updates kommen über das neu gebaute Image, nicht über dnf auf dem Rechner.
dnf5 config-manager setopt mullvad-stable.enabled=0

# =============================================================================
# Signaturprüfung für das eigene Image
# =============================================================================
# Trägt in /etc/containers/policy.json eine Regel ein: Images aus
# ghcr.io/aguano/bluefin-mullvad werden nur mit gültiger cosign-Signatur
# angenommen, geprüft gegen den öffentlichen Schlüssel aus system_files/.
# Wirksam wird die Prüfung auf dem Rechner erst nach einmaligem
#   sudo bootc switch --enforce-container-sigpolicy ghcr.io/aguano/bluefin-mullvad:latest
# Die Einträge der Basis (ublue-os, toolbx, Red Hat) bleiben erhalten,
# deshalb wird die Datei per jq ergänzt statt ersetzt.

POLICY="/etc/containers/policy.json"
SIGN_KEY="/usr/lib/pki/containers/bluefin-mullvad.pub"
SIGN_REPO="ghcr.io/aguano/bluefin-mullvad"

# --- 7. Vorbedingungen prüfen (Build bricht ab, falls etwas fehlt) -----------
# Schlüssel und registries.d-Datei müssen aus system_files/ angekommen sein
grep -q "BEGIN PUBLIC KEY" "${SIGN_KEY}"
test -s /etc/containers/registries.d/bluefin-mullvad.yaml
test -s "${POLICY}"

# --- 8. Regel ergänzen ---------------------------------------------------------
# Setzt nur den Eintrag für das eigene Repository; alles andere bleibt unverändert
jq --arg repo "${SIGN_REPO}" --arg key "${SIGN_KEY}" \
   '.transports.docker[$repo] = [{
       "type": "sigstoreSigned",
       "keyPath": $key,
       "signedIdentity": {"type": "matchRepository"}
    }]' \
   "${POLICY}" > /tmp/policy.json.new
# Inhalt zurückschreiben statt die Datei zu ersetzen: Rechte und
# SELinux-Kennzeichnung der Originaldatei bleiben so erhalten
cat /tmp/policy.json.new > "${POLICY}"
rm /tmp/policy.json.new

# --- 9. Selbstkontrolle --------------------------------------------------------
# jq -e endet mit Fehler, wenn das Ergebnis false oder null ist → Build bricht ab.
# Eine unlesbare policy.json würde auf dem Rechner jeden Download blockieren,
# auch den zur Reparatur. Deshalb wird hier streng geprüft.
# a) Datei ist gültiges JSON, die neue Regel ist vorhanden und korrekt
jq -e --arg repo "${SIGN_REPO}" --arg key "${SIGN_KEY}" \
   '.transports.docker[$repo][0].type == "sigstoreSigned"
    and .transports.docker[$repo][0].keyPath == $key' "${POLICY}"
# b) Einträge der Basis sind erhalten geblieben
jq -e '.transports.docker["ghcr.io/ublue-os"] != null' "${POLICY}"
jq -e '.default[0].type == "reject"' "${POLICY}"
