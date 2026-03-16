;; svtr-vault.clar - Turkey Sovereign Bond Vault (27% APR)
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-AMOUNT (err u101))
(define-constant ERR-INVALID-LOCK-DAYS (err u102))
(define-constant ERR-INSUFFICIENT-BALANCE (err u103))

(define-fungible-token svTR)

(define-map lock-multiplier uint uint)
(impl (insert-entry! lock-multiplier u30 u8000))
(impl (insert-entry! lock-multiplier u60 u8500))
(impl (insert-entry! lock-multiplier u90 u9000))
(impl (insert-entry! lock-multiplier u180 u9500))
(impl (insert-entry! lock-multiplier u365 u10000))

(define-map lock-penalty uint uint)
(impl (insert-entry! lock-penalty u30 u2500))
(impl (insert-entry! lock-penalty u60 u2200))
(impl (insert-entry! lock-penalty u90 u1800))
(impl (insert-entry! lock-penalty u180 u1000))
(impl (insert-entry! lock-penalty u365 u700))

(define-constant PROTOCOL_FEE_BPS u1000)
(define-constant NOTICE_BLOCKS u1440)
(define-constant BASE_APR u2700)  ;; 27%

(define-map positions
  principal
  {
    principal: uint,
    deposit-block: uint,
    lock-days: uint,
    apr-bps: uint,
    yield-earned: uint,
    notice-given: bool,
    notice-ready-block: uint
  }
)

(define-data-var total-deposited uint u0)
(define-data-var total-supply uint u0)

(define-public (deposit (usdc-amount uint) (lock-days uint))
  (let
    (
      (caller tx-sender)
      (multiplier (unwrap! (map-get? lock-multiplier lock-days) ERR-INVALID-LOCK-DAYS))
      (effective-apr (/ (* BASE_APR multiplier) u10000))
    )
    (try! (ft-mint? svTR usdc-amount caller))
    (map-set positions caller
      {
        principal: usdc-amount,
        deposit-block: block-height,
        lock-days: lock-days,
        apr-bps: effective-apr,
        yield-earned: u0,
        notice-given: false,
        notice-ready-block: u0
      }
    )
    (var-set total-deposited (+ (var-get total-deposited) usdc-amount))
    (var-set total-supply (+ (var-get total-supply) usdc-amount))
    (print { event: "deposited", user: caller, amount: usdc-amount, lock-days: lock-days })
    (ok true)
  )
)

(define-public (redeem)
  (let
    (
      (caller tx-sender)
      (pos (unwrap! (map-get? positions caller) ERR-INSUFFICIENT-BALANCE))
      (shares (ft-get-balance svTR caller))
    )
    (asserts! (> shares u0) ERR-INSUFFICIENT-BALANCE)
    (try! (ft-burn? svTR shares caller))
    (map-delete positions caller)
    (var-set total-deposited (- (var-get total-deposited) (get principal pos)))
    (var-set total-supply (- (var-get total-supply) shares))
    (print { event: "redeemed", user: caller, amount: shares })
    (ok true)
  )
)

(define-read-only (get-position (user principal))
  (map-get? positions user)
)

(define-read-only (get-total-deposited)
  (ok (var-get total-deposited))
)
