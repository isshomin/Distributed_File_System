# Docker 기반 GlusterFS 분산 파일 시스템 구축 🗃

---

## 목적 ✒
이 프로젝트의 목적은 GlusterFS를 이용해 세 대의 서버에 분산 스토리지를 구성하고, Docker 컨테이너에서 공유 디렉토리를 마운트함으로써 **데이터 복제와 고가용성을 실현하는 것**입니다. 서버 하나가 중단되더라도 다른 서버에서 데이터를 계속 사용할 수 있도록 하여, 
장애 상황에서도 **안정적인 스토리지 서비스를 유지하는 데 중점**을 둡니다.

<br>

## 초기설정 ⚙
각 VM의 고정IP를 설정합니다.
<br>

```ymal
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s3:
      addresses:
        - 10.0.2.31/24
      routes:
        - to: default
          via: 10.0.2.1
      nameservers:
        addresses:
          - 8.8.8.8
      dhcp4: false
```
<br>
    서버1: 10.0.2.31
		서버2: 10.0.2.32
		서버3: 10.0.2.33

<br>

## 스크립트 실행 ✔

### apt 업데이트 및 Docker 설치 🐳
```bash
sudo apt-get update -y

echo "@@@@ docker 설치진행함 @@@@"
if ! command -v docker &> /dev/null; then
  sudo apt install -y ca-certificates curl gnupg lsb-release
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -y
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
else
  echo "@@@@ docker가 설치되어있음 @@@@"
fi

docker --version
```
각종 패키지 설치 전, 최신 패키지 정보를 불러옵니다. <br>
컨테이너 기반 운영을 위한 Docker 설치를 자동으로 처리하고 이미 설치되어 있다면 단계를 건너뜁니다.

<br>

### GlusterFS 설치 📦
```bash
sudo apt install -y software-properties-common
sudo add-apt-repository ppa:gluster/glusterfs-11 -y
sudo apt-get update -y
sudo apt install -y glusterfs-server -y
sudo systemctl enable glusterd --now
```
분산 파일 시스템 구성을 위한 GlusterFS 설치입니다.

<br>

### brick 디렉토리 정리 및 생성 🧹
```bash
sudo umount /mnt/shared || true
sudo rm -rf /gluster/brick1/*
sudo mkdir -p /gluster/brick1
sudo mkdir -p /mnt/shared
```
기존 데이터는 제거하고 brick과 mount 디렉토리를 새로 구성합니다.

<br>

### peer 연결 및 볼륨 생성 및 시작 (Only Master Node) 🤝
```bash
for NODE in "${NODE_LIST[@]}"; do
  if [[ "$NODE" != "$MASTER_NODE" ]]; then
    sudo gluster peer probe "$NODE"
  fi
done

sudo gluster volume create sharedvol replica 3 \
  10.0.2.31:/gluster/brick1 \
  10.0.2.32:/gluster/brick1 \
  10.0.2.33:/gluster/brick1 force

sudo gluster volume start sharedvol
```
세 노드의 brick을 묶어 하나의 복제 볼륨을 생성하고 생성한 GlusterFS 볼륨을 노드에 마운트합니다.

<br>

### 볼륨 마운트 및 fstab 등록 🔗
```bash
sudo mount -t glusterfs 10.0.2.31:/sharedvol /mnt/shared

echo "10.0.2.31:/sharedvol /mnt/shared glusterfs defaults,_netdev 0 0" | sudo tee -a /etc/fstab
```
생성한 GlusterFS 볼륨을 노드에 마운트하고 재부팅 후에도 자동 마운트되도록 /etc/fstab에 등록합니다.

<br>

### 노드별 Docker 컨테이너 이름 설정 🧷
```bash
CONTAINER_NAME="gfs_node_$(echo $THIS_NODE | cut -d'.' -f4)"
```
ip 마지막 자리를 붙여 각 노드에 고유한 컨테이너 이름을 부여합니다.

<br>

### Docker 컨테이너 실행 및 볼륨 연결 🚀
```bash
sudo docker rm -f ${CONTAINER_NAME} || true
sudo docker run -dit --name ${CONTAINER_NAME} -v /mnt/shared:/mnt/shared ubuntu sh
```
볼륨을 컨테이너에 마운트한 뒤 백그라운드로 실행합니다.

<br>

### 마운트 확인 ✅
```bash
mount | grep gluster
```
sharedvol이 /mnt/shared에 마운트되어 있는지 각 서버에서 확인합니다.
```bash
출력: 10.0.2.31:/sharedvol on /mnt/shared type fuse.glusterfs (rw,relatime,user_id=0,group_id=0,default_permissions,allow_other,max_read=131072)
```

<br>

---

## 테스트 절차 🧪

### ✅ Step1: 각 컨테이너에서 파일 작성

```bash
# 서버1(10.0.2.31)
docker exec -it gfs_node_31 bash -c "echo 'server1' > /mnt/shared/file1"

# 서버2(10.0.2.32)
docker exec -it gfs_node_32 bash -c "echo 'server2' > /mnt/shared/file2"

# 서버3(10.0.2.33)
docker exec -it gfs_node_33 bash -c "echo 'server3' > /mnt/shared/file3"
```
<br>

### ✅ Step2: 파일 확인
```bash
# 임의의 서버에서 실행
cat /mnt/shared/file*
docker exec -it gfs_node_32 bash -c "cat /mnt/shared/file*"
```
<img width="323" height="93" alt="image" src="https://github.com/user-attachments/assets/cd661418-ac98-4a64-afc1-cfc86867f0a9" />
<br>
<img width="572" height="89" alt="image" src="https://github.com/user-attachments/assets/2ef86e18-1e18-4af1-9f29-90e3aa95e6c8" />

<br>
<br>
<br>

### ✅ Step3: 임의의 서버 1대 중단 후 확인(서버2 중단)
<img width="1426" height="474" alt="image" src="https://github.com/user-attachments/assets/70e7156f-a094-45a7-8fb6-6c6f82647dd4" />

GlusterFS의 replica구조 덕분에 하나의 서버가 중단되더라도 나머지 노드에서 여전히 데이터 접근이 가능합니다.

<br>

---

## 트러블슈팅 🔧💥

### Docker 컨테이너 실행 실패 ⚠️

<img width="1580" height="142" alt="image" src="https://github.com/user-attachments/assets/14cee906-65e5-4ced-b6c3-b7a6753a40cb" />

<br>
<br>

### 원인추론 ⛅
```bash
sudo docker run -dit --name ${CONTAINER_NAME} -v ${MOUNT_PATH}:${MOUNT_PATH} alpine bash
```
- 사용한 Docker 이미지인 alpine은 기본적으로 bash가 설치되어 있지 않음
- 그 결과 bash를 실행하려다 실행 파일을 찾을 수 없어 컨테이너가 종료됨

<br>

### 해결 🌞
```bash
sudo docker run -dit --name ${CONTAINER_NAME} -v ${MOUNT_PATH}:${MOUNT_PATH} ubuntu sh
```
이미지를 ubuntu로 교체하고, 실행 명령어를 sh로 변경하여 해결
<br>
- ubuntu는 sh가 기본 내장되어 있어 실행 오류가 발생하지 않음

---
