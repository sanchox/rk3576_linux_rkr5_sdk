# rk3576_linux_rkr5_sdk

This SDK is used to compile firmware for Debian and buildroot systems for armsom products sige5 and cm5io.

## compile step

### 1.Select the development board configuration

```
$ ./build.sh lunch
Log colors: message notice warning error fatal

Log saved at /home/lhd/customized_project/3576/rk3576_linux_rkr5/linux/output/sessions/2025-02-14_10-37-25
Pick a defconfig:

1. rockchip_defconfig
2. rockchip_rk3576_armsom_cm5_defconfig
3. rockchip_rk3576_armsom_sige5_defconfig
4. rockchip_rk3576_evb1_v10_defconfig
5. rockchip_rk3576_industry_evb_v10_defconfig
6. rockchip_rk3576_iotest_v10_defconfig
7. rockchip_rk3576_ipc_evb1_v10_defconfig
8. rockchip_rk3576_multi_ipc_evb1_v10_defconfig
9. rockchip_rk3576_test1_v10_defconfig
10. rockchip_rk3576_test2_v10_defconfig
Which would you like? [1]: 
```

according to the requirements, keyboard input can be used to select
[2]: cm5io and [3]: sige5.

### 2.Compile firmware

Compile complete firmware:

```
./build.sh
```

It is recommended to execute this after downloading the SDK.

Compile the Uboot:

```
./build.sh uboot
```

Compile the Kernel:

```
./build.sh kernel
```

run `./build.sh` system will compile the buildroot system by default

rootfs can be specified by setting the environment variable `RK_SOOTFSYSTEM`.
If you need to build rootfs, you can generate it using the following command:

```
export RK_ROOTFS_SYSTEM=debian
export RK_ROOTFS_SYSTEM=buildroot
```

The generated image is stored in the `rockdev` directory

### 3.Online upgrade system

Put the compiled image into the board and execute the corresponding dd instruction to upgrade the kernel and uboot

```
##kernel updating
dd conv=fsync,notrunc if=/data/app/boot.img of=/dev/disk/by-partlabel/boot

##uboot updating
dd conv=fsync,notrunc if=/data/app/uboot/uboot.img of=/dev/disk/by-partlabel/uboot
```
