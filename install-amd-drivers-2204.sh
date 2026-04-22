sudo apt install "linux-headers-$(uname -r)" "linux-modules-extra-$(uname -r)"


## 22.04LTS
#ROCm installation


wget https://repo.radeon.com/amdgpu-install/7.1/ubuntu/jammy/amdgpu-install_7.1.70100-1_all.deb
sudo chown -Rv _apt:root /var/cache/apt/archives/partial/
sudo chmod -Rv 700 /var/cache/apt/archives/partial/
sudo apt install ./amdgpu-install_7.1.70100-1_all.deb -y
sudo apt update
sudo apt install python3-setuptools python3-wheel -y
sudo usermod -a -G render,video $USER # Add the current user to the render and video groups
sudo apt install rocm -y

sudo apt update
sudo apt install "linux-headers-$(uname -r)" "linux-modules-extra-$(uname -r)"
sudo apt install amdgpu-dkms -y

sudo apt install environment-modules -y
sudo usermod -a -G video,render $USER
echo 'ADD_EXTRA_GROUPS=1' | sudo tee -a /etc/adduser.conf
echo 'EXTRA_GROUPS=video' | sudo tee -a /etc/adduser.conf
echo 'EXTRA_GROUPS=render' | sudo tee -a /etc/adduser.conf

#Grant GPU access to all users on the system
sudo apt update
wget https://repo.radeon.com/amdgpu/30.10.1/ubuntu/pool/main/a/amdgpu-insecure-instinct-udev-rules/amdgpu-insecure-instinct-udev-rules_30.10.1.0-2212064.22.04_all.deb
sudo chown -Rv _apt:root /var/cache/apt/archives/partial/
sudo chmod -Rv 700 /var/cache/apt/archives/partial/
sudo apt install ./amdgpu-insecure-instinct-udev-rules_30.10.1.0-2212064.22.04_all.deb


sudo groupadd devteam
sudo usermod -a -G devteam $USER
sudo usermod -a -G render $USER
sudo usermod -a -G video $USER
sudo udevadm control --reload-rules && sudo udevadm trigger
sudo reboot
