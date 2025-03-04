(use-modules (gnu)
             (gnu system)
             (gnu system nss)
             (gnu packages))

(operating-system
 (host-name "guix-wsl")
 (timezone "America/Los_Angeles")
 (locale "en_US.utf8")
 (users (cons (user-account
               (name "user")
               (comment "user")
               (group "users")
               (supplementary-groups
                '("wheel" "audio" "video")))
              %base-user-accounts))
 (packages %base-packages)
 (bootloader (bootloader-configuration
              (bootloader grub-efi-bootloader)
              (targets '("/boot/efi"))))

 (file-systems (cons*
                (file-system
                 (mount-point "/")
                 (device "/dev/vda1")
                 (type "ext4"))
                %base-file-systems))
 (services
  (modify-services
   %base-services)))
