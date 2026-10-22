;; Guix System for WSL2.
;;
;; image.scm builds the release tarball from this file and installs a copy
;; of it as /etc/config.scm on first boot.  Edit that copy, then:
;;
;;   sudo guix system reconfigure /etc/config.scm
;;
;; It is upstream's (gnu system images wsl2) operating system with fixes
;; for problems that otherwise appear after the first restart or the first
;; reconfigure.  Needs Guix from 2026-09-17 or later (make-wsl-os).

(use-modules (gnu)
             (gnu system images wsl2)
             ((gnu packages base)
              #:select (coreutils libc-utf8-locales-for-target))
             ((gnu packages bash) #:select (bash))
             ((gnu packages guile) #:select (guile-3.0))
             ((guix utils) #:select (%current-system))
             ((guix build syscalls) #:prefix syscalls:)
             (srfi srfi-1))

(define %user "guest")
(define %uid 1000)
(define %host "gnu")

;; Upstream boots from root's login shell, so its wsl.conf's [user]
;; default=%user skips the boot after any `wsl --terminate' or host
;; reboot.  Boot from WSL's [boot] command instead: WSL runs it as root
;; at every distro start, outside any wsl.exe session, so shepherd ends
;; up under WSL's init and outlives the session that started the distro.
;; Upstream's login steps that need root happen here too.  Shepherd's
;; socket is visible to root alone, so once it exists, create
;; %wsl-booted for login shells to wait on.
(define %wsl-booted "/run/wsl-booted")

(define (wsl-boot-command user)
  (program-file
   "wsl-boot-command"
   (with-imported-modules '((guix build syscalls))
     #~(begin
         (use-modules (guix build syscalls))
         (define socket "/var/run/shepherd/socket")
         (setsid)
         (let ((null (open-fdes "/dev/null" O_RDONLY))
               (log (open-fdes "/var/log/wsl-boot.log"
                               (logior O_WRONLY O_CREAT O_APPEND)
                               #o640)))
           (dup2 null 0)
           (dup2 log 1)
           (dup2 log 2))
         (unless (file-exists? "/run/current-system")
           (when (file-exists? socket)
             (delete-file socket))
           ;; WSL mounts /run nosuid, which breaks /run/privileged/bin.
           (mount #f "/run" #f MS_REMOUNT #:update-mtab? #f)
           ;; The child boots the system and becomes shepherd.
           (when (zero? (primitive-fork))
             (let* ((generation (readlink "/var/guix/profiles/system"))
                    (system (readlink
                             (if (absolute-file-name? generation)
                                 generation
                                 (string-append "/var/guix/profiles/"
                                                generation)))))
               (setenv "GUIX_NEW_SYSTEM" system)
               (execl #$(file-append guile-3.0 "/bin/guile")
                      "guile" "--no-auto-compile"
                      (string-append system "/boot"))))
           (let wait ()
             (unless (file-exists? socket)
               (usleep 100000)
               (wait)))
           ;; Only now: on the first start, activation creates USER.
           (let* ((pw (getpw #$user))
                  (runtime-dir (string-append "/run/user/"
                                              (number->string
                                               (passwd:uid pw)))))
             (unless (file-exists? runtime-dir)
               (mkdir runtime-dir #o700)
               (chown runtime-dir (passwd:uid pw) (passwd:gid pw))))
           (close-port (open-output-file #$%wsl-booted)))))))

;; WSL starts the first session's login shell without waiting for the
;; [boot] command, and /etc/profile needs the booted system: wait for
;; it, for at most a minute.  Root can also go by shepherd's socket,
;; which serves sessions started between a reconfigure and the next
;; distro start (WSL's default user is still root then).
;;
;; The first start after `wsl --import' has no /etc yet, so no wsl.conf
;; and no [boot] command.  WSL then starts /bin/sh as root, which the
;; image makes root's login shell: this script.  It starts the boot
;; command itself, then waits like any other start.  Without
;; /etc/passwd, WSL also set HOME (and the directory, by default) to /.
;; /root appears only when shepherd's user-homes service has run, which
;; can be after the socket: wait for it too, up to ten seconds.
;;
;; /etc/profile resets PATH, so keep WSL's, with the Windows PATH, as
;; $WSLPATH.  WSL's XDG_RUNTIME_DIR is WSLg's, shared by every distro
;; and outliving this one; use /run/user/UID.  Bash, not Guile: before
;; boot, Guile finds no locales and warns.
(define (wsl-login-shell shell boot-command)
  (computed-file
   "wsl-login-shell"
   #~(begin
       (call-with-output-file #$output
         (lambda (port)
           (display (string-append "#!" #$shell "
first=
if [ ! -e /etc/wsl.conf ] && [ ! -e /run/current-system ]; then
    first=1
    " #$boot-command " </dev/null >>/var/log/wsl-boot.log 2>&1 &
fi
i=0
until [ -e " #$%wsl-booted " ] ||
      { [ -e /run/current-system ] && [ -S /var/run/shepherd/socket ]; }; do
    if [ $i -eq 600 ]; then
        echo 'wsl-login-shell: not booted after 60 s, see /var/log/wsl-boot.log' >&2
        break
    fi
    " #$(file-append coreutils "/bin/sleep") " 0.1
    i=$((i + 1))
done
if [ -n \"$first\" ]; then
    export HOME=/root
    i=0
    while [ ! -d /root ] && [ $i -lt 100 ]; do
        " #$(file-append coreutils "/bin/sleep") " 0.1
        i=$((i + 1))
    done
    [ \"$PWD\" = / ] && cd /root
fi
export WSLPATH=$PATH SHELL=" #$shell "
[ -d /run/user/$UID ] && export XDG_RUNTIME_DIR=/run/user/$UID
exec " #$shell " -l \"$@\"
")
                    port)))
       (chmod #$output #o555))))

;; drvfs mounts take the WSL default user's IDs, so /mnt/c is %user's.
(define %wsl-conf
  (mixed-text-file "wsl.conf" "\
[user]
default=" %user "

[boot]
systemd=false
command=" (wsl-boot-command %user) "

[automount]
enabled=true
root=/mnt

[network]
hostname=" %host "
generateHosts=true
generateResolvConf=true

[interop]
enabled=true
appendWindowsPath=true
"))

;; WSL mounts / itself.  `guix system reconfigure' still wants a root
;; file system holding the store, and checks that its device exists:
;; name whatever WSL mounted on / right now (/dev/sdX; the letter
;; depends on attach order).  Nothing mounts it, and WSL's `mount -a'
;; skips /.  `guix system image' replaces it with a root of its own.
(define %root-device
  (or (any (lambda (mount)
             (and (string=? (syscalls:mount-point mount) "/")
                  (syscalls:mount-source mount)))
           (syscalls:mounts))
      "none"))

;; Guix's essential cleanup service empties /tmp, /var/run and /run at
;; boot.  WSL mounts a fresh /run at every start, already holding the
;; session interop sockets (/run/WSL/*_interop): deleting them leaves
;; the first terminal after a restart unable to run .exe files.  Same
;; cleanup, minus /run.
(define (wsl-cleanup-gexp _)
  (with-imported-modules '((guix build utils))
    #~(begin
        (use-modules (guix build utils))
        (for-each (lambda (thunk)
                    (catch 'system-error thunk (const #f)))
                  (list (lambda () (delete-file "/etc/group.lock"))
                        (lambda () (delete-file "/etc/passwd.lock"))
                        (lambda () (delete-file "/etc/.pwd.lock"))
                        (lambda ()
                          (setenv "GUIX_LOCPATH"
                                  #+(file-append
                                     (libc-utf8-locales-for-target
                                      (%current-system))
                                     "/lib/locale"))
                          (setlocale LC_CTYPE "en_US.utf8"))
                        (lambda () (delete-file-recursively "/tmp"))
                        (lambda () (delete-file-recursively "/var/run"))
                        (lambda () (mkdir "/tmp" #o1777) (chmod "/tmp" #o1777))
                        (lambda ()
                          (mkdir "/var/run" #o755)
                          (chmod "/var/run" #o755)))))))

(define wsl-cleanup-service-type
  (service-type
    (name 'wsl-cleanup)
    (extensions
     (list (service-extension boot-service-type wsl-cleanup-gexp)))
    (description "Like cleanup-service-type, but leave WSL's /run alone.")))

(define %base-os
  (make-wsl-os #:user %user #:uid %uid #:hostname %host))

(operating-system
  (inherit %base-os)
  (essential-services
   (map (lambda (s)
          (if (eq? (service-kind s) cleanup-service-type)
              (service wsl-cleanup-service-type #f)
              s))
        (operating-system-default-essential-services
         this-operating-system)))
  (file-systems (list (file-system
                        (mount-point "/")
                        (device %root-device)
                        (type "ext4")
                        (check? #f))))
  (users (map (lambda (account)
                (if (member (user-account-name account) (list "root" %user))
                    (user-account
                      (inherit account)
                      (shell (wsl-login-shell
                              (file-append bash "/bin/bash")
                              (wsl-boot-command %user))))
                    account))
              (operating-system-users %base-os)))
  (services
   (cons (simple-service 'wsl-conf etc-service-type
                         `(("wsl.conf" ,%wsl-conf)))
         (remove (lambda (service)
                   (eq? (service-type-name (service-kind service))
                        'wsl-meta))
                 (operating-system-user-services %base-os)))))
