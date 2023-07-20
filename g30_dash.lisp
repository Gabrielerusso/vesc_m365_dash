; G30 dashboard compability lisp script v0.8 by AKA13 and 1zuna
; UART Wiring: red=5V black=GND yellow=COM-TX (UART-HDX) green=COM-RX (button)+3.3V with 1K Resistor
; Guide (German): https://rollerplausch.com/threads/vesc-controller-einbau-1s-pro2-g30.6032/
; Tested on VESC 6.05 BETA on G30D w/ MP2

; -> User parameters (change these to your needs)
(def software-adc 1)
(def min-adc-throttle 0.1)
(def min-adc-brake 0.1)

(def show-batt-in-idle 1)
(def min-speed 1)
(def button-safety-speed (/ 0.1 3.6)) ; disabling button above 0.1 km/h (due to safety reasons)

; Speed modes (km/h, watts, current scale)
(def eco-speed (/ 7 3.6))
(def eco-current 0.6)
(def eco-watts 400)
(def drive-speed (/ 17 3.6))
(def drive-current 0.7)
(def drive-watts 500)
(def sport-speed (/ 21 3.6))
(def sport-current 1.0)
(def sport-watts 700)

; Secret speed modes. To enable, press the button 2 times while holding break and throttle at the same time.
(def secret-enabled 1)
(def secret-eco-speed (/ 27 3.6))
(def secret-eco-current 0.8)
(def secret-eco-watts 1200)
(def secret-drive-speed (/ 47 3.6))
(def secret-drive-current 0.9)
(def secret-drive-watts 1500)
(def secret-sport-speed (/ 1000 3.6)) ; 1000 km/h easy
(def secret-sport-current 1.0)
(def secret-sport-watts 1500000)

; -> Code starts here (DO NOT CHANGE ANYTHING BELOW THIS LINE IF YOU DON'T KNOW WHAT YOU ARE DOING)

; Packet handling
(uart-start 115200 'half-duplex)
(gpio-configure 'pin-rx 'pin-mode-in-pu)
(define tx-frame (array-create 15))
(bufset-u16 tx-frame 0 0x5AA5) ;Ninebot protocol
(bufset-u8 tx-frame 2 0x06) ;Payload length is 5 bytes
(bufset-u16 tx-frame 3 0x2021) ; Packet is from ESC to BLE
(bufset-u16 tx-frame 5 0x6400) ; Packet is from ESC to BLE
(def uart-buf (array-create 64))

; Button handling

(def buttonold 0)
(def presstime (systime))
(def presses 0)

; Mode states

(def off 0)
(def lock 0)
(def speedmode 4)
(def light 0)
(def unlock 0)

; Sound feedback

(def feedback 0)

(if (= software-adc 1)
    (app-adc-detach 3 1)
    (app-adc-detach 3 0)
)

(defun adc-input(buffer) ; Frame 0x65
    {
        (let ((current-speed (* (get-speed) 3.6))
            (throttle (/(bufget-u8 uart-buf 5) 255.0))
            (brake (/(bufget-u8 uart-buf 6) 255.0)))
            {
                (if (< throttle 0)
                    (setf throttle 0))
                (if (> throttle 1)
                    (setf throttle 1))
                (if (< brake 0)
                    (setf brake 0))
                (if (> brake 1)
                    (setf brake 1))
                
                ; Pass through throttle and brake to VESC
                (app-adc-override 0 throttle)
                (app-adc-override 1 brake)
            }
        )
    }
)

(defun handle-features()
    {
        (if (or (= off 1) (= lock 1))
            (if (not (app-is-output-disabled)) ; Disable output when scooter is turned off
                {
                    (app-adc-override 0 0)
                    (app-adc-override 1 0)
                    (app-disable-output -1)
                }
                
            )
            (if (app-is-output-disabled) ; Enable output when scooter is turned on
                (app-disable-output 0)
            )
        )
        
        (if (= lock 1)
            {
                (set-current-rel 0) ; No current input when locked
                (if (> (* (get-speed) 3.6) min-speed)
                    (set-brake-rel 1) ; Full power brake
                    (set-brake-rel 0) ; No brake
                )
            }
        )
    }
)

(defun update-dash(buffer) ; Frame 0x64
    {
        ; mode field (1=drive, 2=eco, 4=sport, 8=charge, 16=off, 32=lock)
        (if (= off 1)
            (bufset-u8 tx-frame 7 16)
            (if (= lock 1)
                (bufset-u8 tx-frame 7 32) ; lock display
                (if (or (> (get-temp-fet) 60) (> (get-temp-mot) 60)) ; temp icon will show up above 60 degree
                    (bufset-u8 tx-frame 7 (+ 128 speedmode))
                    (bufset-u8 tx-frame 7 speedmode)
                )
                
            )
        )
        
        ; batt field
        (bufset-u8 tx-frame 8 (*(get-batt) 100))

        ; light field
        (if (= off 0)
            (bufset-u8 tx-frame 9 light)
            (bufset-u8 tx-frame 9 0)
        )
        
        ; beep field
        (if (= lock 1)
            (if (> (* (get-speed) 3.6) min-speed)
                (bufset-u8 tx-frame 10 1) ; beep lock
                (bufset-u8 tx-frame 10 0))
            (if (> feedback 0)
                {
                    (bufset-u8 tx-frame 10 1)
                    (set 'feedback (- feedback 1))
                }
                (bufset-u8 tx-frame 10 0)
            )
        )

        ; speed field
        (if (= (+ show-batt-in-idle unlock) 2)
            (if (> (* (get-speed) 3.6) 1)
                (bufset-u8 tx-frame 11 (* (get-speed) 3.6))
                (bufset-u8 tx-frame 11 (*(get-batt) 100)))
            (bufset-u8 tx-frame 11 (* (get-speed) 3.6))
        )
        
        ; error field
        (bufset-u8 tx-frame 12 (get-fault))

        ; calc crc

        (setvar 'crcout 0)
        (looprange i 2 13
        (setvar 'crcout (+ crcout (bufget-u8 tx-frame i))))
        (setvar 'crcout (bitwise-xor crcout 0xFFFF))
        (bufset-u8 tx-frame 13 crcout)
        (bufset-u8 tx-frame 14 (shr crcout 8))

        ; write
        (uart-write tx-frame)
    }
)

(defun read-frames()
    (loopwhile t
        {
            (uart-read-bytes uart-buf 3 0)
            (if (= (bufget-u16 uart-buf 0) 0x5aa5)
                {
                    (setvar 'len (bufget-u8 uart-buf 2))
                    (setvar 'crc len)
                    (if (and (> len 0) (< len 60)) ; max 64 bytes
                        {
                            (uart-read-bytes uart-buf (+ len 6) 0) ;read remaining 6 bytes + payload, overwrite buffer

                            (let ((code (bufget-u8 uart-buf 2)) (checksum (bufget-u16 uart-buf (+ len 4))))
                                (looprange i 0 (+ len 4) (setvar 'crc (+ crc (bufget-u8 uart-buf i))))
                                
                                (if (= checksum (bitwise-and (+ (shr (bitwise-xor crc 0xFFFF) 8) (shl (bitwise-xor crc 0xFFFF) 8)) 65535)) ;If the calculated checksum matches with sent checksum, forward comman
                                    (handle-frame code)
                                )
                            )
                        }
                    )
                }
            )
        }
    )
)

(defun handle-frame(code)
    {
        (if (and (= code 0x65) (= software-adc 1))
            (adc-input uart-buf)
        )
        
        (if(= code 0x64)
            (update-dash uart-buf)
        )
    }
)

(defun handle-button()
    (if (= presses 1) ; single press
        (if (= off 1) ; is it off? turn on scooter again
            {
                (set 'off 0) ; turn on
                (set 'feedback 1) ; beep feedback
                (set 'unlock 0) ; Disable unlock on turn off
                (apply-mode) ; Apply mode on start-up
                (stats-reset) ; reset stats when turning on
            }
            (set 'light (bitwise-xor light 1)) ; toggle light
        )
        (if (>= presses 2) ; double press
            {
                (if (> (get-adc-decoded 1) min-adc-brake) ; if brake is pressed
                    (if (and (= secret-enabled 1) (> (get-adc-decoded 0) min-adc-throttle))
                        {
                            (set 'unlock (bitwise-xor unlock 1))
                            (set 'feedback 2) ; beep 2x
                            (apply-mode)
                        }
                        {
                            (set 'unlock 0)
                            (apply-mode)
                            (set 'lock (bitwise-xor lock 1)) ; lock on or off
                            (set 'feedback 1) ; beep feedback
                        }
                    )
                    {
                        (if (= lock 0)
                            {
                                (cond
                                    ((= speedmode 1) (set 'speedmode 4))
                                    ((= speedmode 2) (set 'speedmode 1))
                                    ((= speedmode 4) (set 'speedmode 2))
                                )
                                (apply-mode)
                            }
                        )
                    }
                )
            }
        )
    )
)

(defun handle-holding-button()
    {
        (if (= (+ lock off) 0) ; it is locked and off?
            {
                (set 'unlock 0) ; Disable unlock on turn off
                (apply-mode)
                (set 'off 1) ; turn off
                (set 'feedback 1) ; beep feedback
            }
        )
    }
)

(defun reset-button()
    {
        (set 'presstime (systime)) ; reset press time again
        (set 'presses 0)
    }
)

; Speed mode implementation

(defun apply-mode()
    (if (= unlock 0)
        (if (= speedmode 1)
            (configure-speed drive-speed drive-watts drive-current)
            (if (= speedmode 2)
                (configure-speed eco-speed eco-watts eco-current)
                (if (= speedmode 4)
                    (configure-speed sport-speed sport-watts sport-current)
                )
            )
        )
        (if (= speedmode 1)
            (configure-speed secret-drive-speed secret-drive-watts secret-drive-current)
            (if (= speedmode 2)
                (configure-speed secret-eco-speed secret-eco-watts secret-eco-current)
                (if (= speedmode 4)
                    (configure-speed secret-sport-speed secret-sport-watts secret-sport-current)
                )
            )
        )
    )
)

(defun configure-speed(speed watts current)
    {
        (conf-set 'max-speed speed)
        (conf-set 'l-watt-max watts)
        (conf-set 'l-current-max-scale current)
        
        (loopforeach i (can-list-devs)
            {
                (can-cmd i (str-merge "(conf-set 'max-speed " (str-from-n speed) ")"))
                (can-cmd i (str-merge "(conf-set 'l-watt-max " (str-from-n watts) ")"))
                (can-cmd i (str-merge "(conf-set 'l-current-max-scale " (str-from-n current) ")"))
            }
        )
    }
)

; Apply mode on start-up
(apply-mode)

; Spawn UART reading frames thread
(spawn 150 read-frames)

(loopwhile t
    {
        (if (> buttonold (gpio-read 'pin-rx))
            {
                (set 'presses (+ presses 1))
                (set 'presstime (systime))
            }
            (if (> (- (systime) presstime) 2500) ; after 2500 ms
                (if (= (gpio-read 'pin-rx) 0) ; check button is still pressed
                    (if (> (- (systime) presstime) 6000) ; long press after 6000 ms
                        {
                            (if (<= (get-speed) button-safety-speed)
                                (handle-holding-button)
                            )
                            (reset-button) ; reset button
                        }
                    )
                    { ; when button not pressed
                        (if (> presses 0) ; if presses > 0
                            {
                                (if (<= (get-speed) button-safety-speed)
                                    (handle-button) ; handle button presses
                                )
                                (reset-button) ; reset button
                            }
                        )
                    }
                )
            )
        )

        (set 'buttonold (gpio-read 'pin-rx))

        (handle-features)
        (sleep 0.05) ; Recude load on the CPU
    }
)