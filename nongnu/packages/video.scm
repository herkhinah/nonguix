;;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Copyright © 2022 Jelle Licht <jlicht@fsfe.org>

(define-module (nongnu packages video)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages video)
  #:use-module (guix build utils)
  #:use-module (guix build-system cmake)
  #:use-module (guix git-download)
  #:use-module (guix packages)
  #:use-module ((guix licenses) #:prefix license:))

(define-public gmmlib
  (package
    (name "gmmlib")
    (version "22.2.0")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/intel/gmmlib")
                    (commit (string-append "intel-gmmlib-" version))))
              (file-name (git-file-name name version))
              (sha256
               (base32
		"0cn8pkb7ahmdmj4m6nd0l8s91pz43snnjjp7vhzbmqa8hsp8wbav"))))
    (build-system cmake-build-system)
    (arguments
     ;; Tests are run as part of the normal build step
     '(#:tests? #f))
    (home-page "https://github.com/intel/gmmlib")
    (synopsis "Intel Graphics Memory Management Library")
    (description
     "This package provides device specific and buffer management for the
Intel Graphics Compute Runtime for OpenCL and the Intel Media Driver
for VAAPI.")
    (license license:expat)))

(define-public intel-media-driver
  (package
    (name "intel-media-driver")
    (version "22.5.4")
    (source (origin
              (method git-fetch)
              (uri (git-reference
                    (url "https://github.com/intel/media-driver")
                    (commit (string-append "intel-media-" version))))
              (file-name (git-file-name name version))
              (sha256
               (base32
		 "0pdmw5357yl9qjw5i9112v5ny19ymi85kl03jd882qcygna3sf8q"))))
    (build-system cmake-build-system)
    (inputs (list libva gmmlib))
    (native-inputs (list pkg-config))
    (arguments
     '(#:tests? #f ;Tests are run as part of the normal build step
       #:configure-flags
       (list "-DENABLE_NONFREE_KERNELS=OFF"
             (string-append "-DLIBVA_DRIVERS_PATH="
                            (assoc-ref %outputs "out") "/lib/dri"))))
    ;; XXX Because of <https://issues.guix.gnu.org/issue/22138>, we need to add
    ;; this to all VA-API back ends instead of once to libva.
    (native-search-paths
     (list (search-path-specification
            (variable "LIBVA_DRIVERS_PATH")
            (files '("lib/dri")))))
    (supported-systems '("i686-linux" "x86_64-linux"))
    (home-page "https://github.com/intel/media-driver")
    (synopsis "Intel Media Driver for VAAPI")
    (description
     "This package provides a VA-API user mode driver supporting hardware
accelerated decoding, encoding, and video post processing for the GEN based
graphics hardware.")
    (license (list license:expat license:bsd-3))))

intel-media-driver
