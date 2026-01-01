terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.33"
    }
  }
}

provider "aws" {
  region                      = var.aws_region
  insecure                    = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2 = "https://${var.zcompute_ip}/api/v2/aws/ec2"
  }
}

########################
# Network (minimal)
########################

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
}

resource "aws_subnet" "main" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidr
  availability_zone = var.availability_zone
}

resource "aws_security_group" "allow_all" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

########################
# Cloud-init
########################

locals {
  cloud_init = <<EOF
#cloud-config
package_update: true
packages:
  - stress-ng
  - fio
  - sysstat
  - iotop
runcmd:
  - |
      set -eux
      DEV="/dev/xvdb"
      MNT="/mnt/data"
      if ! blkid $DEV; then
        mkfs.ext4 $DEV
      fi
      mkdir -p $MNT
      mount $DEV $MNT
      echo "$DEV $MNT ext4 defaults,nofail 0 2" >> /etc/fstab

      LOG_DIR="/var/log/zadara-stress"
      mkdir -p "$LOG_DIR"

      (iostat -xm 2 > "$LOG_DIR/iostat.log") &
      (vmstat 2 > "$LOG_DIR/vmstat.log") &

      stress-ng --timeout 45m --metrics-brief \
        --hdd 6 --hdd-bytes 90% --hdd-opts fsync \
        --temp-path "$MNT" \
        --log-file "$LOG_DIR/stress-ng.log" || true

      fio --name=data-stress \
        --directory="$MNT" \
        --rw=randrw \
        --rwmixread=50 \
        --bs=4k \
        --ioengine=libaio \
        --iodepth=64 \
        --numjobs=4 \
        --size=80% \
        --time_based \
        --runtime=1800 \
        --direct=1 \
        --fsync=1 \
        --group_reporting \
        --output="$LOG_DIR/fio.log" || true
EOF
}

########################
# Instances
########################

resource "aws_instance" "vm" {
  count         = 10
  ami           = var.ami_id
  instance_type = var.instance_type
  key_name      = var.key_pair_name

  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.allow_all.id]

  user_data = local.cloud_init

  tags = {
    Name = "zadara-io-vm-${count.index}"
  }
}

########################
# Data Volumes (15GB)
########################

resource "aws_ebs_volume" "data" {
  count             = 10
  availability_zone = var.availability_zone
  size              = 15
  type              = "gp2"
}

resource "aws_volume_attachment" "attach" {
  count       = 10
  device_name = "/dev/xvdb"
  volume_id   = aws_ebs_volume.data[count.index].id
  instance_id = aws_instance.vm[count.index].id
}
