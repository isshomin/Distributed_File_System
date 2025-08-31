#!/bin/bash

set -e

NODE_LIST=("10.0.2.31" "10.0.2.32" "10.0.2.33")
MASTER_NODE="10.0.2.31"

BRICK_PATH="/gluster/brick1"
MOUNT_PATH="/mnt/shared"
VOLUME_NAME="sharedvol"

sudo apt-get update -y

# docker 설치
echo "@@@@ docker 설치진행함 @@@@"
if ! command -v docker &> /dev/null; then
  sudo apt install -y ca-certificates curl gnupg lsb-release
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -y
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
else
  echo "@@@@ docker가 설치되어있음 @@@@"
fi

docker --version

# GlusterFS 설치
echo "@@@@ GlusterFS 설치진행 @@@@"
sudo apt install -y software-properties-common
sudo add-apt-repository ppa:gluster/glusterfs-11 -y
sudo apt-get update -y
sudo apt install -y glusterfs-server -y
sudo systemctl enable glusterd --now

# brick 초기화
sudo umount ${MOUNT_PATH} || true
sudo rm -rf ${BRICK_PATH}/*
sudo mkdir -p ${BRICK_PATH}
sudo mkdir -p ${MOUNT_PATH}

THIS_NODE=$(hostname -I | awk '{print $1}')
echo "server ip: ${THIS_NODE}"

# master에서만 peer, volume 생성
if [[ "$THIS_NODE" == "$MASTER_NODE" ]]; then
  echo "@@ 다른 노드와 peer 연결 중임 @@"

  for NODE in "${NODE_LIST[@]}"; do
    if [[ "$NODE" != "$MASTER_NODE" ]]; then
      if sudo gluster peer probe "$NODE"; then
        echo "@@ ${NODE} peer 연결 완료했음 @@"
      else
        echo "@@ ${NODE} peer 연결 실패했음 @@"
      fi
    fi
  done

  for i in {1..15}; do
    CONNECTED=$(sudo gluster peer status | grep -c "Connected")
    if [[ "$CONNECTED" -eq 2 ]]; then
      echo "@@ 모든 노드가 정상 연결됨 @@"
      break
    fi
    echo "@@ 연결되지 않은 노드가 있음(${i}/15) @@"
    sleep 2
  done

  echo "@@@@ volume 생성, 시작 중임 @@@@"
  BRICK_ARGS=""
  for NODE in "${NODE_LIST[@]}"; do
    BRICK_ARGS="${BRICK_ARGS} ${NODE}:${BRICK_PATH}"
  done

  if sudo gluster volume create "${VOLUME_NAME}" replica 3 ${BRICK_ARGS} force; then
    sudo gluster volume start "${VOLUME_NAME}"
  else
    echo "@@@@ volume 생성에 실패함 / sudo gluster volume status로 peer 체크해보세요!!! @@@@"
  fi

else
  echo "@@@@ volume 생성 검증 @@@@"
  for i in {1..15}; do
    if sudo gluster volume info | grep -q "${VOLUME_NAME}"; then
      echo "@@ volume 생성 감지 완료함 @@"
      break
    fi
    echo "@@ volume 생성 대기중임(${i}/15) @@"
    sleep 2
  done
fi

# mount, fstab 등록
echo "@@@@ GlusterFS mount 시작함 @@@@"
sudo mount -t glusterfs ${MASTER_NODE}:/${VOLUME_NAME} ${MOUNT_PATH}

if ! grep -q "${MASTER_NODE}:/${VOLUME_NAME}" /etc/fstab; then
  echo "${MASTER_NODE}:/${VOLUME_NAME} ${MOUNT_PATH} glusterfs defaults,_netdev 0 0" | sudo tee -a /etc/fstab
fi

echo "@@ mount 검증 중 @@"
if ! mount | grep -q gluster; then
  echo "@@ mount 실패 @@"
  exit 1
fi

# docker 컨테이너 실행
echo "@@@@ docker container 실행 @@@@"
CONTAINER_NAME="gfs_node_$(echo $THIS_NODE | cut -d'.' -f4)"

sudo docker rm -f ${CONTAINER_NAME} || true
sudo docker run -dit --name ${CONTAINER_NAME} -v ${MOUNT_PATH}:${MOUNT_PATH} ubuntu sh

echo "@@ ${CONTAINER_NAME} 생성완료 -> ${MOUNT_PATH}에 GlusterFS mount됨 @@"
