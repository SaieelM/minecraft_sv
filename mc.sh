#!/bin/bash
# Minecraft on GCP - Phase 2
#  - The world is backed up to Cloud Storage every time the server stops,
#    and restored when a new VM starts. The VM itself is throwaway.
#  - A cleanup job (Cloud Scheduler -> Cloud Run function, every 2 min) deletes
#    stopped VMs, but ONLY after checking their backup is newer than their last start.
#
# One time:   bash mc.sh setup
# Then:       bash mc.sh up | stop | status | logs | cmd "op Name"
#             rebuild (new settings, same world) | delete (VM only) | wipe (VM + world)
#             cleanup-now (run the cleanup job immediately)
set -euo pipefail

# ---- settings (override like: MC_VERSION=26.3 bash mc.sh up) ----
NAME=${NAME:-mc-test}                 # also the server ID: world -> gs://BUCKET/NAME/world.tgz
REGION=asia-south1                    # Mumbai
ZONE=${ZONE:-asia-south1-a}
MACHINE=${MACHINE:-e2-standard-2}     # 2 vCPU, 8 GB
MC_VERSION=${MC_VERSION:-1.21.4}      # the version most of your players use
ONLINE_MODE=${ONLINE_MODE:-FALSE}     # FALSE = any launcher can join; TRUE = Microsoft accounts only

# Old 1.x versions need Java 21; new 26.x versions need the newest Java.
if [[ $MC_VERSION == 1.* ]]; then IMAGE=itzg/minecraft-server:java21
else IMAGE=itzg/minecraft-server:latest; fi

PROJECT=$(gcloud config get-value project 2>/dev/null || true)
if [ -z "$PROJECT" ]; then
  echo "No project set. Run: gcloud config set project YOUR_PROJECT_ID"; exit 1
fi
BUCKET=mc-backups-$PROJECT
VM_SA=mc-game-vm@$PROJECT.iam.gserviceaccount.com
CLEAN_SA=mc-cleaner@$PROJECT.iam.gserviceaccount.com
SCHED_SA=mc-scheduler@$PROJECT.iam.gserviceaccount.com

# ======================================================================
# Startup script: runs as root on EVERY boot of a game VM
# ======================================================================
STARTUP=$(cat <<'EOF'
#!/bin/bash
MD=http://metadata.google.internal/computeMetadata/v1/instance/attributes
H="Metadata-Flavor: Google"
ID=$(curl -s -H "$H" $MD/server-id)
BUCKET=$(curl -s -H "$H" $MD/backup-bucket)
BACKUP="gs://$BUCKET/$ID/world.tgz"
stop_requested() { [ "$(curl -s -H "$H" "$MD/mc-stop$1")" = "true" ]; }

# 1. Docker (first boot only)
if ! command -v docker >/dev/null; then
  apt-get update
  apt-get -o DPkg::Lock::Timeout=300 install -y docker.io
fi

# 2. Restore the world, but only onto an empty disk (never overwrite newer local data)
mkdir -p /mc-data
if [ -z "$(ls -A /mc-data)" ]; then
  if gcloud storage cp "$BACKUP" /tmp/world.tgz 2>/dev/null; then
    tar -xzf /tmp/world.tgz -C /mc-data && rm -f /tmp/world.tgz
    echo "Restored world from $BACKUP"
  else
    echo "No backup at $BACKUP yet - starting a new world"
  fi
fi

# 3. Watch for "bash mc.sh stop" (it sets metadata mc-stop=true). Waits without polling.
( until stop_requested "" || stop_requested "?wait_for_change=true&timeout_sec=300"; do sleep 1; done
  echo "Stop requested - saving world"
  until docker stop -t 60 mc 2>/dev/null; do sleep 5; done ) &

# 4. Run Minecraft. Blocks while people play; returns on autostop (10 empty min) or Stop.
START=$(date +%s)
docker rm -f mc 2>/dev/null
docker run --rm --name mc --stop-timeout 60 -v /mc-data:/data -p 25565:25565 \
  -e EULA=TRUE -e TYPE=PAPER -e VERSION=__VERSION__ -e ONLINE_MODE=__ONLINE__ \
  -e MEMORY=6G -e MOTD="GCP test server" \
  -e ENABLE_AUTOSTOP=TRUE -e AUTOSTOP_TIMEOUT_EST=600 -e AUTOSTOP_TIMEOUT_INIT=900 \
  -e MODRINTH_PROJECTS="viaversion?,viabackwards?" \
  __IMAGE__

# 5. Crashed right after starting (and nobody pressed Stop)? Stay on so logs can be read.
if [ $(( $(date +%s) - START )) -lt 300 ] && ! stop_requested ""; then
  echo "Minecraft exited early - NOT backing up. Check the logs above."; exit 1
fi

# 6. Back up, and power off ONLY if the upload worked.
echo "Backing up world to $BACKUP"
if tar -czf /tmp/world.tgz -C /mc-data . && gcloud storage cp /tmp/world.tgz "$BACKUP"; then
  echo "Backup OK - powering off"; poweroff
else
  echo "BACKUP FAILED - staying on so the world is not lost"
fi
EOF
)
STARTUP=${STARTUP//__VERSION__/$MC_VERSION}
STARTUP=${STARTUP//__ONLINE__/$ONLINE_MODE}
STARTUP=${STARTUP//__IMAGE__/$IMAGE}

# ======================================================================
# Cleanup function (Node.js). Later this becomes the website's
# POST /internal/reconcile endpoint.
# ======================================================================
write_cleanup_code() {
  mkdir -p "$HOME/mc-cleanup"
  cat > "$HOME/mc-cleanup/package.json" <<'EOF'
{
  "name": "mc-cleanup",
  "version": "1.0.0",
  "main": "index.js",
  "engines": { "node": ">=22" },
  "dependencies": {
    "@google-cloud/compute": "^7.0.0",
    "@google-cloud/functions-framework": "^5.0.0",
    "@google-cloud/storage": "^8.0.0"
  }
}
EOF
  cat > "$HOME/mc-cleanup/index.js" <<'EOF'
// Deletes Minecraft VMs that have powered off, but ONLY if their world backup
// in Cloud Storage is newer than the VM's last start, so a world is never lost.
// Cloud Scheduler calls this every 2 minutes.
const functions = require('@google-cloud/functions-framework');
const { InstancesClient } = require('@google-cloud/compute');
const { Storage } = require('@google-cloud/storage');

const { PROJECT, ZONE, BUCKET } = process.env;
const instances = new InstancesClient();
const bucket = new Storage().bucket(BUCKET);

async function backupTime(serverId) {
  try {
    const [meta] = await bucket.file(`${serverId}/world.tgz`).getMetadata();
    return Date.parse(meta.updated);
  } catch (e) {
    if (e.code === 404) return 0; // no backup yet
    throw e;
  }
}

async function cleanup() {
  const [vms] = await instances.list({ project: PROJECT, zone: ZONE });
  const log = [];
  for (const vm of vms) {
    // only our game VMs, and only ones that have powered themselves off
    if (vm.labels?.mc_server !== 'true' || vm.status !== 'TERMINATED') continue;
    const id = vm.labels.server_id || vm.name;
    const started = Date.parse(vm.lastStartTimestamp || vm.creationTimestamp);
    const backedUp = await backupTime(id);
    if (backedUp > started) {
      await instances.delete({ project: PROJECT, zone: ZONE, instance: vm.name });
      log.push(`deleted ${vm.name} (backup from ${new Date(backedUp).toISOString()})`);
    } else {
      log.push(`KEPT ${vm.name}: no backup newer than its last start - check it by hand`);
    }
  }
  return log.length ? log.join('\n') : 'nothing to clean up';
}

functions.http('cleanup', async (req, res) => {
  try {
    const msg = await cleanup();
    console.log(msg);
    res.send(msg + '\n');
  } catch (e) {
    console.error(e);
    res.status(500).send(String(e) + '\n');
  }
});

module.exports = { cleanup };
EOF
}

# ======================================================================
# Helpers
# ======================================================================
retry() {  # new service accounts take a few seconds to become usable
  local i; for i in 1 2 3 4 5 6; do "$@" && return 0; echo "  (retrying in 10s...)"; sleep 10; done
  return 1
}
vm_status() {
  gcloud compute instances describe "$NAME" --zone="$ZONE" --format='value(status)' 2>/dev/null || true
}
vm_is_ours() {  # made by this Phase 2 script (has backups + label)?
  [ "$(gcloud compute instances describe "$NAME" --zone="$ZONE" \
       --format='value(labels.mc_server)' 2>/dev/null)" = "true" ]
}
get_ip() {
  gcloud compute instances describe "$NAME" --zone="$ZONE" \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
}
show_backup() {
  gcloud storage ls -l "gs://$BUCKET/$NAME/" 2>/dev/null | grep world.tgz || echo "  (no backup yet)"
}
wait_ready() {
  local ip; ip=$(get_ip)
  echo "VM IP: $ip  (waiting for Minecraft; a new VM takes ~3-5 min)"
  for _ in $(seq 1 60); do
    if timeout 3 bash -c "</dev/tcp/$ip/25565" 2>/dev/null; then
      echo; echo "READY -> Minecraft > Multiplayer > Edit/Direct Connect > $ip"; return
    fi
    printf '.'; sleep 10
  done
  echo; echo "Not up yet. Check progress with: bash mc.sh logs"
}

# ======================================================================
# Commands
# ======================================================================
setup() {
  echo "== Enabling APIs (a minute or two) =="
  gcloud services enable compute.googleapis.com storage.googleapis.com iam.googleapis.com \
    cloudfunctions.googleapis.com run.googleapis.com cloudbuild.googleapis.com \
    artifactregistry.googleapis.com cloudscheduler.googleapis.com logging.googleapis.com

  echo "== Firewall: port 25565 open only to VMs tagged mc-server =="
  gcloud compute firewall-rules describe allow-minecraft >/dev/null 2>&1 || \
    gcloud compute firewall-rules create allow-minecraft --network=default --direction=INGRESS \
      --action=ALLOW --rules=tcp:25565 --target-tags=mc-server --source-ranges=0.0.0.0/0

  echo "== Backup bucket gs://$BUCKET (versioned, keeps 3 older copies) =="
  gcloud storage buckets describe "gs://$BUCKET" >/dev/null 2>&1 || \
    gcloud storage buckets create "gs://$BUCKET" --location=$REGION --uniform-bucket-level-access
  echo '{"rule":[{"action":{"type":"Delete"},"condition":{"numNewerVersions":3,"isLive":false}}]}' \
    > /tmp/mc-lifecycle.json
  gcloud storage buckets update "gs://$BUCKET" --versioning
  gcloud storage buckets update "gs://$BUCKET" --lifecycle-file=/tmp/mc-lifecycle.json
  gcloud storage buckets update "gs://$BUCKET" --clear-soft-delete

  echo "== Service accounts (each gets only what it needs) =="
  local sa
  for sa in mc-game-vm mc-cleaner mc-scheduler; do
    gcloud iam service-accounts describe "$sa@$PROJECT.iam.gserviceaccount.com" >/dev/null 2>&1 || \
      gcloud iam service-accounts create "$sa" --display-name="Minecraft $sa"
  done
  sleep 10
  # game VMs: read/write backups in the bucket, nothing else
  retry gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
    --member="serviceAccount:$VM_SA" --role=roles/storage.objectAdmin >/dev/null
  # cleanup function: list/delete VMs, read backup times
  retry gcloud projects add-iam-policy-binding "$PROJECT" --condition=None \
    --member="serviceAccount:$CLEAN_SA" --role=roles/compute.instanceAdmin.v1 >/dev/null
  retry gcloud iam service-accounts add-iam-policy-binding "$VM_SA" \
    --member="serviceAccount:$CLEAN_SA" --role=roles/iam.serviceAccountUser >/dev/null
  retry gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
    --member="serviceAccount:$CLEAN_SA" --role=roles/storage.objectViewer >/dev/null
  # newer projects: let Cloud Build build the function
  local num; num=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
  gcloud projects add-iam-policy-binding "$PROJECT" --condition=None \
    --member="serviceAccount:$num-compute@developer.gserviceaccount.com" \
    --role=roles/cloudbuild.builds.builder >/dev/null || true

  echo "== Cleanup function (code saved in ~/mc-cleanup; deploy takes ~2-3 min) =="
  write_cleanup_code
  gcloud functions deploy mc-cleanup --gen2 --runtime=nodejs22 --region=$REGION \
    --source="$HOME/mc-cleanup" --entry-point=cleanup --trigger-http --no-allow-unauthenticated \
    --service-account="$CLEAN_SA" --memory=512Mi --timeout=60s --max-instances=1 \
    --set-env-vars="PROJECT=$PROJECT,ZONE=$ZONE,BUCKET=$BUCKET"
  retry gcloud functions add-invoker-policy-binding mc-cleanup --region=$REGION \
    --member="serviceAccount:$SCHED_SA" >/dev/null
  local url
  url=$(gcloud functions describe mc-cleanup --gen2 --region=$REGION --format='value(serviceConfig.uri)')

  echo "== Scheduler: run the cleanup every 2 minutes =="
  local verb=create
  gcloud scheduler jobs describe mc-cleanup --location=$REGION >/dev/null 2>&1 && verb=update
  gcloud scheduler jobs $verb http mc-cleanup --location=$REGION --schedule="*/2 * * * *" \
    --uri="$url" --http-method=POST \
    --oidc-service-account-email="$SCHED_SA" --oidc-token-audience="$url"

  echo; echo "Setup done. Next: bash mc.sh rebuild  (or: bash mc.sh up)"
}

up() {
  if ! gcloud storage buckets describe "gs://$BUCKET" >/dev/null 2>&1; then
    echo "Run the one-time setup first:  bash mc.sh setup"; exit 1
  fi
  local st; st=$(vm_status)
  if [ -n "$st" ]; then
    if ! vm_is_ours; then
      echo "'$NAME' was made by the old script (no backups). Replace it with: bash mc.sh rebuild"
      exit 1
    fi
    case $st in
      RUNNING) echo "Already running."; wait_ready; return ;;
      TERMINATED)
        echo "== Starting stopped '$NAME' again (its world is still on its disk) =="
        gcloud compute instances add-metadata "$NAME" --zone="$ZONE" --metadata=mc-stop=false
        gcloud compute instances start "$NAME" --zone="$ZONE"
        wait_ready; return ;;
      *) echo "'$NAME' is $st right now. Try again in a minute."; exit 1 ;;
    esac
  fi
  echo "== Creating '$NAME': Paper $MC_VERSION, online-mode=$ONLINE_MODE (image $IMAGE) =="
  echo "   World backup: gs://$BUCKET/$NAME/world.tgz (restored automatically if it exists)"
  printf '%s\n' "$STARTUP" > /tmp/mc-startup.sh
  gcloud compute instances create "$NAME" --zone="$ZONE" --machine-type="$MACHINE" \
    --image-family=debian-12 --image-project=debian-cloud \
    --boot-disk-size=20GB --boot-disk-type=pd-balanced \
    --network-tier=STANDARD --tags=mc-server \
    --labels="mc_server=true,server_id=$NAME" \
    --service-account="$VM_SA" --scopes=cloud-platform \
    --metadata-from-file=startup-script=/tmp/mc-startup.sh \
    --metadata="server-id=$NAME,backup-bucket=$BUCKET,mc-stop=false"
  wait_ready
}

stop() {
  local st; st=$(vm_status)
  if [ "$st" != "RUNNING" ]; then
    echo "'$NAME' is not running (${st:-no VM}). World backup:"; show_backup; return
  fi
  if ! vm_is_ours; then   # old-script VM has no stop watcher
    gcloud compute instances stop "$NAME" --zone="$ZONE"; return
  fi
  echo "== Asking '$NAME' to save, back up and power off =="
  gcloud compute instances add-metadata "$NAME" --zone="$ZONE" --metadata=mc-stop=true
  for _ in $(seq 1 30); do
    st=$(vm_status)
    if [ "$st" = "TERMINATED" ] || [ -z "$st" ]; then
      echo; echo "Stopped and backed up. The cleanup job deletes the VM within ~2 min."
      show_backup; return
    fi
    printf '.'; sleep 10
  done
  echo; echo "Still not off after 5 min - check: bash mc.sh logs"
}

status() {
  local st; st=$(vm_status)
  if [ -n "$st" ]; then echo "VM '$NAME': $st   IP: $(get_ip)"
  else echo "VM '$NAME': none (offline; 'bash mc.sh up' recreates it from the backup)"; fi
  echo "World backup:"; show_backup
}

delete() {
  if [ "$(vm_status)" = "RUNNING" ]; then
    echo "WARNING: '$NAME' is running. Progress since its last backup will be lost."
    echo "         Use 'bash mc.sh stop' instead to save first."
  fi
  echo "This deletes the VM only. Any backup in gs://$BUCKET/$NAME/ is kept."
  gcloud compute instances delete "$NAME" --zone="$ZONE"
}

rebuild() {  # new settings (version, online mode...), same world
  local st; st=$(vm_status)
  if [ -n "$st" ] && ! vm_is_ours; then
    echo "== Deleting old-style '$NAME' (it has no backups, its world is not kept) =="
    gcloud compute instances delete "$NAME" --zone="$ZONE" --quiet
    up; return
  fi
  if [ "$st" = "RUNNING" ]; then stop; st=$(vm_status); fi
  if [ "$st" = "RUNNING" ]; then echo "Could not stop cleanly, so not rebuilding."; exit 1; fi
  if [ -n "$st" ]; then gcloud compute instances delete "$NAME" --zone="$ZONE" --quiet; fi
  up
}

wipe() {
  echo "This DELETES the VM and ALL backups of '$NAME'. The next 'up' makes a brand-new world."
  read -r -p "Type the server name ($NAME) to confirm: " ans
  if [ "$ans" != "$NAME" ]; then echo "Cancelled."; exit 1; fi
  gcloud compute instances delete "$NAME" --zone="$ZONE" --quiet 2>/dev/null || true
  gcloud storage rm --all-versions "gs://$BUCKET/$NAME/**" 2>/dev/null || true
  echo "Wiped."
}

case "${1:-}" in
  setup)       setup ;;
  up|start)    up ;;
  stop)        stop ;;
  status)      status ;;
  logs)        gcloud compute instances get-serial-port-output "$NAME" --zone="$ZONE" 2>/dev/null \
                 | grep 'startup-script' | tail -n 40 ;;
  cmd)         gcloud compute ssh "$NAME" --zone="$ZONE" \
                 --command="sudo docker exec mc rcon-cli ${*:2}" ;;
  rebuild)     rebuild ;;
  delete)      delete ;;
  wipe)        wipe ;;
  cleanup-now) gcloud scheduler jobs run mc-cleanup --location=$REGION
               echo "Cleanup triggered. In ~30 s check: bash mc.sh status" ;;
  *) echo "Usage: bash mc.sh setup | up | stop | status | logs | cmd \"op Name\" | rebuild | delete | wipe | cleanup-now" ;;
esac
