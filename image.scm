;; The release image:
;;
;;   guix system image --image-type=wsl2 image.scm
;;
;; It is wsl.scm plus one activation step that installs wsl.scm as an
;; editable /etc/config.scm the first time the system boots.

(use-modules (gnu))

(define %config (local-file "wsl.scm"))

(define os (load "wsl.scm"))

(operating-system
  (inherit os)
  (services
   (cons (simple-service 'install-config.scm activation-service-type
                         #~(unless (file-exists? "/etc/config.scm")
                             (copy-file #$%config "/etc/config.scm")
                             (chmod "/etc/config.scm" #o644)))
         (operating-system-user-services os))))
