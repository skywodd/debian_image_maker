#!/bin/bash
# Création d'une image debian squeeze minimal dans un disque virtuel
# Script d'automatisation du processus de construction de l'image disque

# ----- Configuration bas niveau -----
# Miroir Debian source
DEBIAN_MIRROR="http://ftp.fr.debian.org/debian"

# Proxy (laisser à vide si aucun). Exemple "http://toto:xyz@192.168.1.10:3128/
HTTP_PROXY=""

# Répertoire temporaire de travail
TMPDIR=/tmp

# Distribution Debian cible
DIST=squeeze

# Architecture cible (i386 ou amd64)
ARCH="i386"

# Chemin du disque virtuel final
DISK_PATH="/tmp/$DIST-$ARCH.disk"

# Taille (en Mo) du disque virtuel
DISK_SIZE=490

# Paquets supplémentaires à installer.
DEBS="ssh less console-tools console-data console-common vim"

# Hostname par défaut du systéme final
REMOTE_HOSTNAME="$DIST-1"

# Point de montage de l'image disque
MOUNT_DIR=/tmp/$DIST

# Mot de passe root par défaut
ROOT_PASSWD='toor'

# Adresse IP virtuelle (mode "-net user" de Qemu)
IP=10.0.2.15

# Port pour la redirection de ssh (Qemu)
SSH_REDIR=5555

# Label de la partition virtuelle
DISK_LABEL="Skynux"

# Version de grub à installer
GRUB_VER="grub-pc"

# ----- NE RIEN EDITER APRES CETTE LIGNE -----

# -- Macro-fonction d'affichage d'erreurs --
error() {
    echo "Error: $@ ! " >&2
    exit 1
}

# -- Fonction de création de l'image disque vide
# $1 Path vers le disque virtuel
# $2 Taille du disque virtuel (en Mo)
make_disk() {

    # Test si le fichier de dique virtuel existe déja
    [ -e $1 ] && error "Le fichier de disque virtuel $1 existe déja" || :

    # Récupére la liste des périphériques loop disponible
    LOOP_DEVICES=`losetup -f`

    # Vérifie qu'un périphérique loop est disponible
    echo $LOOP_DEVICES | grep -q '/dev' || error "Aucun périphérique loop disponible"

    # Création du fichier creux
    # 1Mo = 1024 * 1Ko
    logical_size=$(($2 * 1024 * 1024))
    echo "Taille logique de l'image disque :$logical_size octets"
    dd of=$1 count=0 bs=1 seek=$logical_size

    # Calcul de la taille du disque virtuel
    # 255 heads, 63 sectors/track
    cylinders_count=$(($logical_size / (512 * 255 * 63)))
    physical_size=$(($cylinders_count * 512 * 255 * 63))
    blocks_count=$(($physical_size / 1024))
    fsblocks_count=$((($physical_size - 63 * 512) / 1024))
    echo "Taille physique de l'image disque :$physical_size octets"
    echo "Nombre de cylindres : $cylinders_count"
    echo "Nombre de blocks (1024 octets) : $blocks_count"
    echo "Nombre de blocks du systéme de fichier : $fsblocks_count"

    # Configuration du périphérique loop
    losetup $LOOP_DEVICES $1

    # Partitionnage de l'image disque
    set +e
    echo -e 'n\np\n1\n\n\np\nw\n' | /sbin/fdisk -H 255 -S 63 -C $cylinders_count $LOOP_DEVICES
    set -e

    # Démontage de l'image disque
    losetup -d $LOOP_DEVICES

    # Associe un périphérique loop à la première (et unique) partition
    # n'utilise pas la première piste (32256=63*512) !
    losetup -o $((63 * 512)) $LOOP_DEVICES $1

    # Formatage de la partition en ext2 
    mke2fs -j $LOOP_DEVICES -b 1024 $fsblocks_count

    # Fixe le label de la partition
    tune2fs -L $DISK_LABEL $LOOP_DEVICES

    # Démontage de l'image disque
    losetup -d $LOOP_DEVICES
}

# Détermine l'utilisateur qui est passé root pour 
# lancer ce script (s'il existe).
# USER_UID = UID de l'utilisateur parent
# USER_GID = GID de l'utilisateur parent
get_realuser() {

    # Obtient le nom d'utilisateur et le PPID du processus courant
    user=$USER
    ppid=$$

    # Boucle tant que l'utilisateur est root
    while [ "$user" = "root" -a $ppid != 1 ]; do

        # Recherche le PPID / nom d'utilisateur du processus parent
        l=$(ps h o pid,ppid,user -p $ppid | tr -s ' ')
        pid=$(echo $l | cut -d ' ' -f 1)
        ppid=$(echo $l | cut -d ' ' -f 2)
        user=$(echo $l | cut -d ' ' -f 3)
    done

    # Obtient le UID et GID à partir du nom d'utilisateur obtenu
    USER_UID=$(id -u $user)
    USER_GID=$(id -g $user)
}

# Monte la première partition du disque virtuel
# $1 Path vers le disque virtuel
# $2 Point de montage
mount_partition() {

    # Crée le point de montage pour / si nécéssaire
    [ ! -d $2 ] && mkdir $2

    # Test si l'image disque n'est pas déja montée
    if ! mount | grep -q $2; then

        # Montage de l'image disque
        mount -o loop,offset=32256 $1 $2
    fi

    # Test si le /proc de l'image disque n'est pas déja montée
    if ! mount | grep -q $2/proc ; then

        # Crée le point de montage pour /proc si nécéssaire
        [ ! -d $2/proc ] && mkdir $2/proc

        # Montage du /proc de l'image disque
        mount -t proc proc $2/proc
    fi

    # Test si le /sys de l'image disque n'est pas déja montée
    if ! mount | grep -q $2/sys ; then

        # Crée le point de montage pour /sys si nécéssaire
        [ ! -d $2/sys ] && mkdir $2/sys

        # Montage du /sys de l'image disque
        mount -t sysfs sys $2/sys
    fi

    # Crée le point de montage pour /dev si nécéssaire
    [ ! -d $2/dev ] && mkdir $2/dev

    # Bind le /dev du systéme host au /dev du systéme cible
    mount -o bind /dev $2/dev

    # Installe un hook permettant de démonter la partition à l'arret du script
    trap "unmount_partition $2" 0
}

# Démonte la première partition du disque virtuel
# $1 Point de montage
unmount_partition() {

    # Test si le point de montage est réellement monté
    if mount | grep -q $1; then

        # Tue les processus utilisant encore le point de montage
        fuser -mk $1 || :

        # Démontage du point de montage /sys /proc et /
        umount $1/sys || :
        umount $1/proc || :
        umount $1/dev || :
        umount $1  || :

        # Vérifie que le démontage est réussi (ou non)
        if mount | grep $1; then
            error "Impossible de démonter $1"
        else
            echo "$1 démonté avec succès ! "
            return 0
        fi
    fi
}

# Installe un noyau et grub dans le système (via chroot)
# $1 Répertoire racine du systéme cible
install_kernel() {

    # Fix pour éviter un avertissement
    echo "do_initrd = Yes" > $1/etc/kernel-img.conf

    # Sélectionne l'architecture cible
    case $ARCH in
        i386) arch=686;;
        amd64) arch=amd64;;
    esac

    # Recherche le dernier noyau disponible
    KERNEL=$(chroot $1 apt-cache search linux-image | 
            grep 'linux-image-2\.6\.[0-9.-]*'$arch' ' | \
            tail -n 1 | sed -re 's/^([^[:space:]]*).*$/\1/')

    # Installe le noyau
    chroot $1 aptitude -y install $KERNEL

    # Installation de Grub
    chroot $1 aptitude -y install $GRUB_VER

    # Création du dossier grub si nécéssaire
    [ ! -d $1/boot/grub ] && mkdir $1/boot/grub

    # Sélectionne l'architecture cible
    case $ARCH in
        i386) arch="i386";;
        amd64) arch="x86_64";;
    esac

    # Récupération des stages de grub
    local grub_stages=`chroot $1 /bin/sh -c \
                "dpkg -L $GRUB_VER | grep $arch-pc | head -n 1"`
    [ -z "$grub_stages" ] && error "Pas de stages grub"

    # Copie des "stages" de grub dans /boot/grub
    cp -a $1/$grub_stages/* $1/boot/grub

    # Création du fichier menu.lst de Grub
    KVERS=`echo $KERNEL | cut -d '-' -f 3-`
    cat <<EOF > $1/boot/grub/menu.lst
timeout         2
color           cyan/blue white/blue
title           Debian GNU/Linux $KERNEL ($DISK_LABEL)
kernel          /boot/vmlinuz-$KVERS root=LABEL=$DISK_LABEL ro
initrd          /boot/initrd.img-$KVERS
EOF

        # Installation de grub dans le secteur d'amorçage
        #echo -e "
        #        device (hd0) $DISK_PATH
        #        root (hd0,0)
        #        setup (hd0)
        #        " | grub --device-map=/dev/null --no-floppy --no-curses
}

# Configurations diverses
# $1 Répertoire racine du systéme cible
make_configuration() {

    # Met à jour le mdp root
    chroot $1 /bin/sh -c "echo \"root:$ROOT_PASSWD\" | chpasswd"

    # Met à jour le hostname
    echo "$REMOTE_HOSTNAME" > $1/etc/hostname

    # Met à jour /etc/hosts
    cat <<EOF > $1/etc/hosts
127.0.0.1       localhost
EOF
    # Configure eth0
    cat <<EOF > $1/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

    # Installe le layout de clavier français
    chroot $1 install-keymap fr

    # Fait le ménage dans les paquets téléchargés
    chroot $1 aptitude clean

    # Supprime les fichiers udev persistent
    rm -f $1/etc/udev/rules.d/*persistent*
}


# Lance la procédure de création de l'image disque et d'installation de debian squeeze
install_base() {
    
    # Création de l'image disque vide
    make_disk $DISK_PATH $DISK_SIZE

    # Donne les droits sur l'image disque à l'utilisateur courant
    get_realuser; 
    chown $USER_UID:$USER_GID $DISK_PATH

    # Montage de la partition cible
    mount_partition $DISK_PATH $MOUNT_DIR

    # Debootstrap
    debootstrap --arch $ARCH $DIST $MOUNT_DIR $DEBIAN_MIRROR

    # Met à jour le fichier sources.list
    cat <<EOF > $MOUNT_DIR/etc/apt/sources.list
deb http://ftp.fr.debian.org/debian $DIST main
deb http://security.debian.org/ $DIST/updates main
EOF

    # Met à jour /etc/fstab
    cat <<EOF > $MOUNT_DIR/etc/fstab
# /etc/fstab: static file system information.
#   
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
proc            /proc           proc    defaults        0       0
EOF

    # Met à jour la liste des paquets
    chroot $MOUNT_DIR aptitude update

    # Installation des paquets supplémentaires
    chroot $MOUNT_DIR aptitude -y install $DEBS

    # Installe le noyau
    install_kernel $MOUNT_DIR

    # Configuration diverse (clavier, réseau)
    make_configuration $MOUNT_DIR

    # Marque le système comme étant construit par builddeb
    touch $MOUNT_DIR/etc/builddeb
}

# -- Programme principal --
# set -e  # arrêt à la moindre erreur
# set -u  # arrêt si utilisation d'une variable non définie
# set -x  # mode trace
set -eux

[ "$USER" != "root" ] && error "Must to be root" || :

export LANG=C
export DEBIAN_FRONTEND=teletype
export DEBIAN_PRIORITY=critical

[ -n "$HTTP_PROXY" ] && export http_proxy=$HTTP_PROXY

# Démontage du systéme de fichier (si déja monté)
unmount_partition $MOUNT_DIR

# Lancement de l'installation
install_base

# Informations pour l'utilisateur
cat << EOF
Le système est maintenant prét. Pour le lancer exécutez la commande :
kvm -m 1024 -drive file=$DISK_PATH -redir tcp:$SSH_REDIR:$IP:22 -kernel /boot/vmlinuz-$KVERS -initrd /boot/initrd.img-$KVERS -append "root=/dev/sda1"
Vous pouvez vous connecter au système par ssh via la commande :
ssh -p $SSH_REDIR -o NoHostAuthenticationForLocalhost=yes root@localhost
EOF

