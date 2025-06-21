#!/bin/bash

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
    echo "Этот скрипт должен запускаться с правами root" >&2
    exit 1
fi

# 1. Настройка BIND
echo 'include "/var/lib/samba/bind-dns/named.conf";' >> /etc/bind/named.conf

# 2. Настройка KRB5RCACHETYPE
echo 'KRB5RCACHETYPE="none"' >> /etc/sysconfig/bind

# 3. Остановка BIND
systemctl stop bind

#Заметил, что на некоторых версиях альта самба уже включена после установки
systemctl stop samba

# 4-6. Очистка старых конфигураций
rm -f /etc/samba/smb.conf
rm -rf /var/lib/samba
rm -rf /var/cache/samba

# 7. Создание необходимых директорий
mkdir -p /var/lib/samba/sysvol

# 8. Provision домена с BIND9_DLZ
echo "Настройка домена Samba AD DC"
read -p "Введите имя домена (например, example.com): " domain_name
read -p "Введите NetBIOS имя домена (например, EXAMPLE): " netbios_name
read -s -p "Введите пароль администратора: " admin_pass
echo ""

samba-tool domain provision \
    --use-rfc2307 \
    --realm="${domain_name^^}" \
    --domain="$netbios_name" \
    --adminpass="$admin_pass" \
    --server-role=dc \
    --dns-backend=BIND9_DLZ

# Проверка успешности provision
if [ $? -ne 0 ]; then
    echo "Ошибка при настройке домена Samba!" >&2
    exit 1
fi

# 9. Копирование krb5.conf
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

# 10. Включение и запуск Samba
systemctl enable samba --now

# 11. Добавление A-записей
echo -e "\nДобавление A-записей (оставьте пустым для завершения)"
while true; do
    read -p "Введите имя устройства и IP через запятую (например, server1,192.168.1.1): " input
    if [ -z "$input" ]; then
        break
    fi
    
    IFS=',' read -r hostname ip <<< "$input"
    samba-tool dns add 127.0.0.1 "$domain_name" "$hostname" A "$ip" -Uadministrator --password="$admin_pass"
    
    if [ $? -ne 0 ]; then
        echo "Ошибка при добавлении A-записи для $hostname" >&2
    else
        echo "A-запись для $hostname успешно добавлена"
    fi
done

# 12. Создание обратных зон
echo -e "\nСоздание обратных зон (оставьте пустым для завершения)"
while true; do
    read -p "Введите имя обратной зоны (например, 1.168.192.in-addr.arpa): " reverse_zone
    if [ -z "$reverse_zone" ]; then
        break
    fi
    
    samba-tool dns zonecreate 127.0.0.1 "$reverse_zone" -Uadministrator --password="$admin_pass"
    
    if [ $? -ne 0 ]; then
        echo "Ошибка при создании обратной зоны $reverse_zone" >&2
    else
        echo "Обратная зона $reverse_zone успешно создана"
    fi
done

# 12.1 Добавление PTR записей
echo -e "\nДобавление PTR записей в обратные зоны (оставьте пустым для завершения)"
while true; do
    read -p "Введите имя зоны,октет,имя устройства (например, 1.168.192.in-addr.arpa,10,server1): " input
    if [ -z "$input" ]; then
        break
    fi
    
    IFS=',' read -r zone octet hostname <<< "$input"
    samba-tool dns add 127.0.0.1 "$zone" "$octet" PTR "$hostname" -Uadministrator --password="$admin_pass"
    
    if [ $? -ne 0 ]; then
        echo "Ошибка при добавлении PTR записи для $octet в зоне $zone" >&2
    else
        echo "PTR запись для $octet ($hostname) успешно добавлена в зону $zone"
    fi
done

# 13. Добавление CNAME записей
read -p "Хотите добавить CNAME записи? (y/n): " add_cname
if [[ "$add_cname" =~ ^[yYдД] ]]; then
    echo -e "\nДобавление CNAME записей (оставьте пустым для завершения)"
    while true; do
        read -p "Введите alias и целевое имя через запятую (например, www,server1.example.com): " input
        if [ -z "$input" ]; then
            break
        fi
        
        IFS=',' read -r alias target <<< "$input"
        samba-tool dns add 127.0.0.1 "$domain_name" "$alias" CNAME "$target" -Uadministrator --password="$admin_pass"
        
        if [ $? -ne 0 ]; then
            echo "Ошибка при добавлении CNAME записи $alias -> $target" >&2
        else
            echo "CNAME запись $alias -> $target успешно добавлена"
        fi
    done
fi

systemctl enable bind --now
echo -e "\nНастройка завершена успешно!"
