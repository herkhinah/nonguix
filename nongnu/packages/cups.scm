;;; Copyright © 2021 Jonathan Brielmaier <jonathan.brielmaier@web.de>
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

(define-module (nongnu packages cups)
  #:use-module (guix download)
  #:use-module (guix packages)
  #:use-module (gnu packages cups)
  #:use-module (nonguix build-system binary)
  #:use-module (nonguix licenses))

(define-public samsung-unified-printer
  (package
    (name "samsung-unified-printer")
    (version "1.00.39_01.17")
    (source (origin
              (method url-fetch)
              (uri (string-append "https://ftp.ext.hp.com/pub/softlib/software13/printers/SS/SL-C4010ND/uld_V"
                                  version ".tar.gz"))
              (sha256
               (base32
                "03jl2hw7rjcq0cpsq714yaw40v73lsm1qa5z4q2m0i36hhxj2f0c"))))
    (build-system binary-build-system)
    (arguments
     `(#:install-plan
       `(("noarch/license/eula.txt" "/share/doc/samsung-unified-printer/")
         ("noarch/share/ppd/" "/share/ppd/samsung/")
         ("x86_64/rastertospl" "/lib/cups/filter/"))
       #:patchelf-plan
       `(("x86_64/rastertospl" ("cups")))
       #:strip-binaries? #f))
    (inputs
     `(("cups" ,cups-minimal)))
    (synopsis "Propriatary Samsung printer drivers")
    (description "Samsung Unified Linux Driver provides propriatary printer
drivers for laser and multifunctional printers.")
    (supported-systems '("x86_64-linux")) ;; TODO: install i686 files
    ;; Samsung printers are part of HP since 2016
    (home-page "https://support.hp.com/us-en/drivers/printers")
    (license (nonfree "file://eula.txt"))))
