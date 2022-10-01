;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2020 Hebi Li <hebi@lihebi.com>
;;; Copyright © 2020 Malte Frank Gerdes <malte.f.gerdes@gmail.com>
;;; Copyright © 2020, 2021 Jean-Baptiste Volatier <jbv@pm.me>
;;; Copyright © 2020-2022 Jonathan Brielmaier <jonathan.brielmaier@web.de>
;;; Copyright © 2021 Pierre Langlois <pierre.langlois@gmx.com>
;;; Copyright © 2022 Petr Hodina <phodina@protonmail.com>
;;; Copyright © 2022 Alexey Abramov <levenson@mmer.org>
;;; Copyright © 2022 Hilton Chain <hako@ultrarare.space>
;;;
;;; This file is not part of GNU Guix.
;;;
;;; This program is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.
;;;
;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

(define-module (nongnu packages nvidia)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module (guix utils)
  #:use-module ((guix licenses) #:prefix license-gnu:)
  #:use-module ((nonguix licenses) #:prefix license:)
  #:use-module (guix build-system linux-module)
  #:use-module (guix build-system copy)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system trivial)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages bootstrap)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages elf)
  #:use-module (gnu packages freedesktop)
  #:use-module (gnu packages gawk)
  #:use-module (gnu packages gcc)
  #:use-module (gnu packages gl)
  #:use-module (gnu packages glib)
  #:use-module (gnu packages gtk)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages m4)
  #:use-module (gnu packages lsof)
  #:use-module (gnu packages perl)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages python)
  #:use-module (gnu packages video)
  #:use-module (gnu packages web)
  #:use-module (gnu packages xorg)
  #:use-module (nongnu packages linux)
  #:use-module (ice-9 match)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 format)
  #:use-module (ice-9 textual-ports)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1))

; Used for closed-source packages
(define nvidia-version "470.86")

; Used for the open-source kernel module package
(define nversion "515.76")

(define computed-origin-method
  (@@ (guix packages) computed-origin-method))

;; Extract the driver installer and make it a new origin instance for reusing.
(define (make-nvidia-source version installer)
  (origin
    (method computed-origin-method)
    (file-name (string-append "nvidia-driver-" version "-checkout"))
    (sha256 #f)
    (uri
     (delay
       (with-imported-modules '((guix build utils))
         #~(begin
             (use-modules (guix build utils)
                          (ice-9 ftw))
             (set-path-environment-variable
              "PATH" '("bin")
              (list (canonicalize-path #+bash-minimal)
                    (canonicalize-path #+coreutils)
                    (canonicalize-path #+gawk)
                    (canonicalize-path #+grep)
                    (canonicalize-path #+tar)
                    (canonicalize-path #+which)
                    (canonicalize-path #+xz)))
             (setenv "XZ_OPT" (string-join (%xz-parallel-args)))
             (invoke "sh" #$installer "-x")
             (copy-recursively
              (car (scandir (canonicalize-path (getcwd))
                            (lambda (file)
                              (not (member file '("." ".."))))))
              #$output)))))))

(define nvidia-source
  (let ((version nvidia-version))
    (make-nvidia-source
     version
     (origin
       (method url-fetch)
       (uri (string-append
             "https://us.download.nvidia.com/XFree86/Linux-x86_64/"
             version "/NVIDIA-Linux-x86_64-" version ".run"))
       (sha256
        (base32 "0krwcxc0j19vjnk8sv6mx1lin2rm8hcfhc2hg266846jvcws1dsg"))))))

(define-public nvidia-driver
  (package
    (name "nvidia-driver")
    (version nvidia-version)
    (source nvidia-source)
    (build-system linux-module-build-system)
    (arguments
     (list #:linux linux-lts
           #:tests? #f
           #:modules '((guix build linux-module-build-system)
                       (guix build utils)
                       (ice-9 ftw)
                       (ice-9 popen)
                       (ice-9 rdelim)
                       (ice-9 regex)
                       (ice-9 textual-ports))
           #:phases
           #~(modify-phases %standard-phases
               (replace 'build
                 (lambda*  (#:key inputs outputs #:allow-other-keys)
                   ;; We cannot use with-directory-excursion, because the install
                   ;; phase needs to be in the kernel folder. Otherwise no .ko
                   ;; would be installed.
                   (chdir "kernel")
                   ;; Patch Kbuild
                   (substitute* "Kbuild" (("/bin/sh") (which "sh")))
                   (invoke "make" "-j"
                           (string-append "CC=" #$(cc-for-target))
                           (string-append "SYSSRC=" (search-input-directory
                                                     inputs "/lib/modules/build")))))
               (delete 'strip)
               (add-after 'install 'install-copy
                 (lambda* (#:key inputs native-inputs outputs #:allow-other-keys)
                   (chdir "..")
                   (let* ((libdir (string-append #$output "/lib"))
                          (bindir (string-append #$output "/bin"))
                          (etcdir (string-append #$output "/etc")))
                     ;; ------------------------------
                     ;; Copy .so files
                     (for-each
                      (lambda (file)
                        (format #t "Copying '~a'...~%" file)
                        (install-file file libdir))
                      (scandir "." (lambda (name)
                                     (string-contains name ".so"))))

                     (install-file "nvidia_drv.so" (string-append #$output "/lib/xorg/modules/drivers/"))
                     (install-file (string-append "libglxserver_nvidia.so." #$version)
                                   (string-append #$output "/lib/xorg/modules/extensions/"))

                     ;; ICD Loader for OpenCL
                     (let ((file (string-append etcdir "/OpenCL/vendors/nvidia.icd")))
                       (mkdir-p (string-append etcdir "/OpenCL/vendors/"))
                       (call-with-output-file file
                         (lambda (port)
                           (display (string-append #$output "/lib/libnvidia-opencl.so.1") port)))
                       (chmod file #o555))

                     ;; Add udev rules for nvidia
                     (let ((rulesdir (string-append #$output "/lib/udev/rules.d/"))
                           (rules    (string-append #$output "/lib/udev/rules.d/90-nvidia.rules")))
                       (mkdir-p rulesdir)
                       (call-with-output-file rules
                         (lambda (port)
                           (put-string port (format #f "~
KERNEL==\"nvidia\", RUN+=\"@sh@ -c '@mknod@ -m 666 /dev/nvidiactl c $$(@grep@ nvidia-frontend /proc/devices | @cut@ -d \\  -f 1) 255'\"
KERNEL==\"nvidia_modeset\", RUN+=\"@sh@ -c '@mknod@ -m 666 /dev/nvidia-modeset c $$(@grep@ nvidia-frontend /proc/devices | @cut@ -d \\  -f 1) 254'\"
KERNEL==\"card*\", SUBSYSTEM==\"drm\", DRIVERS==\"nvidia\", RUN+=\"@sh@ -c '@mknod@ -m 666 /dev/nvidia0 c $$(@grep@ nvidia-frontend /proc/devices | @cut@ -d \\  -f 1) 0'\"
KERNEL==\"nvidia_uvm\", RUN+=\"@sh@ -c '@mknod@ -m 666 /dev/nvidia-uvm c $$(@grep@ nvidia-uvm /proc/devices | @cut@ -d \\  -f 1) 0'\"
KERNEL==\"nvidia_uvm\", RUN+=\"@sh@ -c '@mknod@ -m 666 /dev/nvidia-uvm-tools c $$(@grep@ nvidia-uvm /proc/devices | @cut@ -d \\  -f 1) 0'\"
"))))
                       (substitute* rules
                         (("@\\<(sh|grep|mknod|cut)\\>@" all cmd)
                          (search-input-file inputs (string-append "/bin/" cmd)))))

                     ;; ------------------------------
                     ;; Add a file to load nvidia drivers
                     (mkdir-p bindir)
                     (let ((file (string-append bindir "/nvidia-insmod"))
                           (moddir (string-append "/lib/modules/" (utsname:release (uname)) "-gnu/extra")))
                       (call-with-output-file file
                         (lambda (port)
                           (put-string port (string-append "#!" (search-input-file inputs "/bin/sh") "\n"
                                                           "modprobe ipmi_devintf"                   "\n"
                                                           "insmod " #$output moddir "/nvidia.ko"         "\n"
                                                           "insmod " #$output moddir "/nvidia-modeset.ko" "\n"
                                                           "insmod " #$output moddir "/nvidia-uvm.ko"     "\n"
                                                           "insmod " #$output moddir "/nvidia-drm.ko"     "\n"))))
                       (chmod file #o555))
                     (let ((file (string-append bindir "/nvidia-rmmod")))
                       (call-with-output-file file
                         (lambda (port)
                           (put-string port (string-append "#!" (search-input-file inputs "/bin/sh") "\n"
                                                           "rmmod " "nvidia-drm"     "\n"
                                                           "rmmod " "nvidia-uvm"     "\n"
                                                           "rmmod " "nvidia-modeset" "\n"
                                                           "rmmod " "nvidia"         "\n"
                                                           "rmmod " "ipmi_devintf"   "\n"))))
                       (chmod file #o555))

                     ;; ------------------------------
                     ;;  nvidia-smi

                     (install-file "nvidia-smi" bindir)

                     ;; ------------------------------
                     ;; patchelf
                     (let* ((ld.so (string-append #$(this-package-input "glibc")
                                                  #$(glibc-dynamic-linker)))
                            (rpath (string-join
                                    (list "$ORIGIN"
                                          (string-append #$output "/lib")
                                          (string-append #$gcc:lib "/lib")
                                          (string-append #$gtk+-2 "/lib")
                                          (string-append #$(this-package-input "atk") "/lib")
                                          (string-append #$(this-package-input "cairo") "/lib")
                                          (string-append #$(this-package-input "gdk-pixbuf") "/lib")
                                          (string-append #$(this-package-input "glib") "/lib")
                                          (string-append #$(this-package-input "glibc") "/lib")
                                          (string-append #$(this-package-input "gtk+") "/lib")
                                          (string-append #$(this-package-input "libx11") "/lib")
                                          (string-append #$(this-package-input "libxext") "/lib")
                                          (string-append #$(this-package-input "pango") "/lib")
                                          (string-append #$(this-package-input "wayland") "/lib"))
                                    ":")))
                       (define (patch-elf file)
                         (format #t "Patching ~a ..." file)
                         (unless (string-contains file ".so")
                           (invoke "patchelf" "--set-interpreter" ld.so file))
                         (invoke "patchelf" "--set-rpath" rpath file)
                         (display " done\n"))
                       (for-each (lambda (file)
                                   (when (elf-file? file)
                                     (patch-elf file)))
                                 (find-files #$output  ".*\\.so"))
                       (patch-elf (string-append bindir "/" "nvidia-smi")))

                     ;; ------------------------------
                     ;; Create short name symbolic links
                     (define (get-soname file)
                       (when elf-file? file
                             (let* ((cmd (string-append "patchelf --print-soname " file))
                                    (port (open-input-pipe cmd))
                                    (soname (read-line port)))
                               (close-pipe port)
                               soname)))

                     (for-each
                      (lambda (lib)
                        (let ((lib-soname (get-soname lib)))
                          (when (string? lib-soname)
                            (let* ((soname (string-append
                                            (dirname lib) "/" lib-soname))
                                   (base (string-append
                                          (regexp-substitute
                                           #f (string-match "(.*)\\.so.*" soname) 1)
                                          ".so"))
                                   (source (basename lib)))
                              (for-each
                               (lambda (target)
                                 (unless (file-exists? target)
                                   (format #t "Symlinking ~a -> ~a..."
                                           target source)
                                   (symlink source target)
                                   (display " done\n")))
                               (list soname base))))))
                      (find-files #$output "\\.so"))
                     (symlink (string-append "libglxserver_nvidia.so." #$version)
                              (string-append #$output "/lib/xorg/modules/extensions/" "libglxserver_nvidia.so"))))))))
    (supported-systems '("x86_64-linux"))
    (native-inputs (list patchelf))
    (inputs
     (list `(,gcc "lib")
           atk
           bash-minimal
           cairo
           coreutils
           gdk-pixbuf
           glib
           glibc
           grep
           gtk+
           gtk+-2
           kmod
           libx11
           libxext
           linux-lts
           pango
           wayland))
    (home-page "https://www.nvidia.com")
    (synopsis "Proprietary NVIDIA driver")
    (description "This is the evil NVIDIA driver.  Don't forget to add
@code{nvidia-driver} to the @code{udev-rules} in your @file{config.scm}:
@code{(simple-service 'custom-udev-rules udev-service-type (list
nvidia-driver))}.  Further xorg should be configured by adding: @code{(modules
(cons* nvidia-driver %default-xorg-modules)) (drivers '(\"nvidia\"))} to
@code{xorg-configuration}.")
    (license
     (license:nonfree
      (format #f "file:///share/doc/nvidia-driver-~a/LICENSE" version)))))

(define-public nvidia-exec
  (package
    (name "nvidia-exec")
    (version "0.1.0")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/pedro00dk/nvidia-exec")
                    (commit (string-append "v" version))))
              (file-name (git-file-name name version))
              (sha256
               (base32
                "079alqgz3drv5mvx059fzhj3f20rnljl7r4yihfd5qq7djgmvv0v"))))
    (build-system copy-build-system)
    (arguments
     (list #:install-plan #~`(("nvx" "bin/"))
           #:modules #~((guix build copy-build-system)
                        (guix build utils)
                        (srfi srfi-1))
           #:phases #~(modify-phases %standard-phases
                        (add-after 'install 'wrap-nvx
                          (lambda* (#:key inputs outputs #:allow-other-keys)
                            (wrap-program (string-append #$output "/bin/nvx")
                                          `("PATH" ":" prefix
                                            ,(fold (lambda (input paths)
                                                     (let* ((in (assoc-ref
                                                                 inputs input))
                                                            (bin (string-append
                                                                  in "/bin")))
                                                       (append (filter
                                                                file-exists?
                                                                (list bin))
                                                               paths)))
                                                   '()
                                                   '("jq" "lshw" "lsof")))))))))
    (inputs (list bash-minimal jq lshw lsof))
    (home-page "https://github.com/pedro00dk/nvidia-exec")
    (synopsis "GPU switching without login out for Nvidia Optimus laptops")
    (description
     "This package provides GPU switching without login out for Nvidia Optimus
laptops.")
    (license license-gnu:gpl3+)))

(define-public nvidia-nvml
  (package
    (name "nvidia-nvml")
    (version "352.79")
    (source
     (origin
       (method url-fetch)
       (uri (string-append "https://developer.download.nvidia.com/compute/cuda/7.5/Prod/gdk/"
                           (format #f "gdk_linux_amd64_~a_release.run"
                                   (string-replace-substring version "." "_"))))
       (sha256
        (base32
         "1r2cwm0j9svaasky3qw46cpg2q6rrazwzrc880nxh6bismyd3a9z"))
       (file-name (string-append "nvidia-nvml-" version "-checkout"))))
    (build-system copy-build-system)
    (arguments
     (list #:phases
           #~(modify-phases %standard-phases
               (replace 'unpack
                 (lambda _
                   (invoke "sh" #$source "--tar" "xvf"))))
           #:install-plan
           ''(("payload/nvml/lib" "lib")
              ("payload/nvml/include" "include/nvidia/gdk")
              ("payload/nvml/example" "src/gdk/nvml/examples")
              ("payload/nvml/doc/man" "share/man")
              ("payload/nvml/README.txt" "README.txt")
              ("payload/nvml/COPYRIGHT.txt" "COPYRIGHT.txt"))))
    (home-page "https://www.nvidia.com")
    (synopsis "The NVIDIA Management Library (NVML)")
    (description "C-based programmatic interface for monitoring and managing various
states within NVIDIA Tesla GPUs.  It is intended to be a platform for
building 3rd party applications, and is also the underlying library for the
NVIDIA-supported nvidia-smi tool.  NVML is thread-safe so it is safe to make
simultaneous NVML calls from multiple threads.")
    ;; Doesn't have any specific LICENSE file, but see COPYRIGHT.txt for details.
    (license (license:nonfree "file://COPYRIGHT.txt"))))

(define-public nvidia-libs
  (package
    (name "nvidia-libs")
    (version nvidia-version)
    (source
     (origin
       (uri (format #f "http://us.download.nvidia.com/XFree86/Linux-x86_64/~a/~a.run"
                    version
                    (format #f "NVIDIA-Linux-x86_64-~a" version)))
       (sha256 (base32 "0krwcxc0j19vjnk8sv6mx1lin2rm8hcfhc2hg266846jvcws1dsg"))
       (method url-fetch)
       (file-name (string-append "nvidia-driver-" version "-checkout"))))
    (build-system copy-build-system)
    (arguments
     `(#:phases
       (modify-phases %standard-phases
         (replace 'unpack
           (lambda* (#:key inputs #:allow-other-keys #:rest r)
             (let ((source (assoc-ref inputs "source")))
               (invoke "sh" source "--extract-only")
               (chdir ,(format #f "NVIDIA-Linux-x86_64-~a" version))
               #t)))
         (delete 'build)
         (delete 'check)
         (add-after 'install 'patch-symlink
             (lambda* (#:key inputs native-inputs outputs #:allow-other-keys)
             (use-modules (ice-9 ftw)
                          (ice-9 regex)
                          (ice-9 textual-ports))
             (let* ((out (assoc-ref outputs "out"))
                    (libdir (string-append out "/lib"))
                    (bindir (string-append out "/bin"))
                    (etcdir (string-append out "/etc")))
               ;; ------------------------------
               ;; patchelf
               (let* ((libc (assoc-ref inputs "libc"))
                      (ld.so (string-append libc ,(glibc-dynamic-linker)))

                      (out (assoc-ref outputs "out"))
                      (rpath (string-join
                              (list "$ORIGIN"
                                    (string-append out "/lib")
                                    (string-append libc "/lib")
                                    (string-append (assoc-ref inputs "atk") "/lib")
                                    (string-append (assoc-ref inputs "cairo") "/lib")
                                    (string-append (assoc-ref inputs "gcc:lib") "/lib")
                                    (string-append (assoc-ref inputs "gdk-pixbuf") "/lib")
                                    (string-append (assoc-ref inputs "glib") "/lib")
                                    (string-append (assoc-ref inputs "gtk+") "/lib")
                                    (string-append (assoc-ref inputs "gtk2") "/lib")
                                    (string-append (assoc-ref inputs "libx11") "/lib")
                                    (string-append (assoc-ref inputs "libxext") "/lib")
                                    (string-append (assoc-ref inputs "pango") "/lib")
                                    (string-append (assoc-ref inputs "wayland") "/lib"))
                              ":")))
                 (define (patch-elf file)
                   (format #t "Patching ~a ...~%" file)
                   (unless (string-contains file ".so")
                     (invoke "patchelf" "--set-interpreter" ld.so file))
                   (invoke "patchelf" "--set-rpath" rpath file))
                 (for-each (lambda (file)
                             (when (elf-file? file)
                               (patch-elf file)))
                           (find-files out  ".*\\.so")))

               ;; ------------------------------
               ;; Create short name symbolic links
               (for-each (lambda (file)
                           (let* ((short (regexp-substitute
                                          #f

                                          (string-match "([^/]*\\.so).*" file)
                                          1))
                                  (major (cond
                                          ((or (string=? short "libGLX.so")
                                               (string=? short "libGLX_nvidia.so")
                                               (string=? short "libEGL_nvidia.so")) "0")
                                          ((string=? short "libGLESv2.so") "2")
                                          (else "1")))
                                  (mid (string-append short "." major))
                                  (short-file (string-append libdir "/" short))
                                  (mid-file (string-append libdir "/" mid)))
                             ;; FIXME the same name, print out warning at least
                             ;; [X] libEGL.so.1.1.0
                             ;; [ ] libEGL.so.435.21
                             (when (not (file-exists? short-file))
                               (format #t "Linking ~a to ~a ...~%" short file)
                               (symlink (basename file) short-file))
                             (when (not (file-exists? mid-file))
                               (format #t "Linking ~a to ~a ...~%" mid file)
                               (symlink (basename file) mid-file))))
                         (find-files libdir "\\.so\\."))
           #t))))
       #:install-plan
        ,@(match (%current-system)
           ("x86_64-linux" '(`(("." "lib" #:include-regexp ("^./[^/]+\\.so")))))
           ("i686-linux" '(`(("32" "lib" #:include-regexp ("^./[^/]+\\.so")))))
           (_ '()))))
    (supported-systems '("i686-linux" "x86_64-linux"))
    (native-inputs
     `(("patchelf" ,patchelf)
       ("perl" ,perl)
       ("python" ,python-2)
       ("which" ,which)
       ("xz" ,xz)))
    (inputs
     `(("atk" ,atk)
       ("cairo" ,cairo)
       ("gcc:lib" ,gcc "lib")
       ("gdk-pixbuf" ,gdk-pixbuf)
       ("glib" ,glib)
       ("gtk+" ,gtk+)
       ("gtk2" ,gtk+-2)
       ("libc" ,glibc)
       ("libx11" ,libx11)
       ("libxext" ,libxext)
       ("wayland" ,wayland)))
    (home-page "https://www.nvidia.com")
    (synopsis "Libraries of the proprietary Nvidia driver")
    (description "These are the libraries of the evil Nvidia driver compatible
with the ones usually provided by Mesa.  To use these libraries with
packages that have been compiled with a mesa output, take a look at the nvda
package.")
    (license (license:nonfree (format #f "file:///share/doc/nvidia-driver-~a/LICENSE" version)))))

(define-public nvidia-module
  (package
    (name "nvidia-module")
    (version nvidia-version)
    (source nvidia-source)
    (build-system linux-module-build-system)
    (arguments
     (list #:linux linux-lts
           #:source-directory "kernel"
           #:tests? #f
           #:make-flags
           #~(list (string-append "CC=" #$(cc-for-target)))
           #:phases
           #~(modify-phases %standard-phases
               (delete 'strip)
               (add-before 'configure 'fixpath
                 (lambda* (#:key (source-directory ".") #:allow-other-keys)
                   (substitute* (string-append source-directory "/Kbuild")
                     (("/bin/sh") (which "sh")))))
               (replace 'build
                 (lambda* (#:key (make-flags '()) (parallel-build? #t)
                           (source-directory ".")
                           inputs
                           #:allow-other-keys)
                   (apply invoke "make" "-C" (canonicalize-path source-directory)
                          (string-append "SYSSRC=" (search-input-directory
                                                    inputs "/lib/modules/build"))
                          `(,@(if parallel-build?
                                  `("-j" ,(number->string
                                           (parallel-job-count)))
                                  '())
                            ,@make-flags)))))))
    (home-page "https://www.nvidia.com")
    (synopsis "Proprietary NVIDIA kernel modules")
    (description
     "This package provides the evil NVIDIA proprietary kernel modules.")
    (license
     (license:nonfree
      (format #f "file:///share/doc/nvidia-driver-~a/LICENSE" version)))))

(define-public nvidia-module-open
  (package
    (name "nvidia-module-open")
    (version nversion)
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/NVIDIA/open-gpu-kernel-modules")
                    (commit nversion)))
              (file-name (git-file-name name version))
              (sha256
               (base32
                "1mkibm0i943ljcy921i63jzc0db6r4pm1ycmwbka9kddcviyb3gk"))))
    (build-system linux-module-build-system)
    (arguments
     (list #:linux linux
           #:source-directory "kernel-open"
           #:tests?  #f
           #:make-flags
           #~(list (string-append "CC=" #$(cc-for-target))
                   (string-append "SYSSRC=" (assoc-ref %build-inputs
                                             "linux-module-builder")
                                  "/lib/modules/build"))
           #:phases
           #~(modify-phases %standard-phases
               (add-after 'unpack 'fixpath
                 (lambda* (#:key inputs outputs #:allow-other-keys)
                   (substitute* "kernel-open/Kbuild"
                     (("/bin/sh") (string-append #$bash-minimal "/bin/sh")))))
               (replace 'build
                 (lambda* (#:key make-flags outputs #:allow-other-keys)
                   (apply invoke
                          `("make" "-j"
                            ,@make-flags "modules")))))))
    (inputs (list bash-minimal))
    (home-page "https://github.com/NVIDIA/open-gpu-kernel-modules")
    (synopsis "Nvidia kernel module")
    (description
     "This package provides Nvidia open-gpu-kernel-modules.  However,
they are only for the latest GPU architectures Turing and Ampere.  Also they
still require firmware file @code{gsp.bin} to be loaded as well as closed
source userspace tools from the corresponding driver release.")
    (license license-gnu:gpl2)))

(define-public nvidia-settings
  (package
    (name "nvidia-settings")
    (version nvidia-version)
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/NVIDIA/nvidia-settings")
                    (commit version)))
              (file-name (git-file-name name version))
              (sha256
               (base32
                "1lnj5hwmfkzs664fxlhljqy323394s1i7qzlpsjyrpm07sa93bky"))))
    (build-system gnu-build-system)
    (arguments
     (list #:tests? #f ;no test suite
           #:make-flags
           #~(list (string-append "PREFIX=" #$output)
                   (string-append "CC=" #$(cc-for-target)))
           #:phases
           #~(modify-phases %standard-phases
               (delete 'configure)
               (add-after 'install 'wrap-program
                 (lambda* (#:key outputs #:allow-other-keys)
                   (let ((out (assoc-ref outputs "out")))
                     (wrap-program (string-append out "/bin/nvidia-settings")
                                   `("LD_LIBRARY_PATH" ":" prefix
                                     (,(string-append out "/lib/"))))))))))
    (native-inputs (list m4
                         pkg-config))
    (inputs (list bash-minimal
                  dbus
                  glu
                  gtk+
                  gtk+-2
                  libvdpau
                  libx11
                  libxext
                  libxrandr
                  libxv
                  libxxf86vm))
    (synopsis "Nvidia driver control panel")
    (description
     "This package provides Nvidia driver control panel for monitor
configuration, creating application profiles, gpu monitoring and more.")
    (home-page "https://github.com/NVIDIA/nvidia-settings")
    (license license-gnu:gpl2)))

;; nvda is used as a name because it has the same length as mesa which is
;; required for grafting
(define-public nvda
  (package
    (inherit nvidia-libs)
    (name "nvda")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list #:modules '((guix build union))
       #:builder #~(begin
                   (use-modules (guix build union)
                                (srfi srfi-1)
                                (ice-9 regex))
                      (union-build (assoc-ref %outputs "out")
                                   (list #$mesa #$nvidia-libs)
                                   #:resolve-collision (lambda (files) (let ((file
                                                                         (if (string-match "nvidia-libs" (first files))
                                                                             (first files)
                                                                             (last files))))
                                                                         (format #t "chosen ~a ~%" file)
                                                                         file))))))
    (description "These are the libraries of the evil Nvidia driver,
packaged in such a way that you can use the transformation option
@code{--with-graft=mesa=nvda} to use the nvidia driver with a package that requires mesa.")
    (inputs
     (list mesa
           nvidia-libs))
    (outputs '("out"))))

(define mesa/fake
  (package
    (inherit mesa)
    (replacement nvda)))

(define-public replace-mesa
  (package-input-rewriting `((,mesa . ,mesa/fake))))
