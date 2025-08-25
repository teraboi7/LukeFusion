;; LukeFusion AMM + Lending Protocol
;; Combines automated market making with lending capacity for optimal capital efficiency

;; Define fungible tokens
(define-fungible-token TK1) ;; First token in the pair
(define-fungible-token TK2) ;; Second token in the pair
(define-fungible-token LP-TOKEN) ;; Liquidity provider tokens
(define-fungible-token LUKE) ;; LukeFusion governance token

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u300))
(define-constant ERR-INSUFFICIENT-BALANCE (err u301))
(define-constant ERR-INSUFFICIENT-LIQUIDITY (err u302))
(define-constant ERR-INVALID-AMOUNT (err u303))
(define-constant ERR-TRANSFER-FAILED (err u304))
(define-constant ERR-MINT-FAILED (err u305))
(define-constant ERR-BURN-FAILED (err u306))
(define-constant ERR-SLIPPAGE-EXCEEDED (err u307))
(define-constant ERR-POOL-NOT-INITIALIZED (err u308))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u309))
(define-constant ERR-LOAN-NOT-FOUND (err u310))
(define-constant ERR-LIQUIDATION-THRESHOLD (err u311))
(define-constant ERR-HEALTH-FACTOR-OK (err u312))

;; Protocol parameters
(define-constant PRECISION u1000000) ;; 6 decimal precision
(define-constant SWAP-FEE u3000) ;; 0.3% swap fee
(define-constant LENDING-FEE u1000) ;; 0.1% lending fee
(define-constant LIQUIDATION-THRESHOLD u800000) ;; 80% LTV
(define-constant LIQUIDATION-BONUS u105000) ;; 5% liquidation bonus
(define-constant MAX-LTV u750000) ;; 75% max loan-to-value
(define-constant MIN-LIQUIDITY u1000) ;; Minimum liquidity lock

;; Data variables
(define-data-var pool-tk1 uint u0)
(define-data-var pool-tk2 uint u0)
(define-data-var total-lp-supply uint u0)
(define-data-var total-tk1-borrowed uint u0)
(define-data-var total-tk2-borrowed uint u0)
(define-data-var tk1-lending-rate uint u50000) ;; 5% APY
(define-data-var tk2-lending-rate uint u50000) ;; 5% APY
(define-data-var protocol-fees-tk1 uint u0)
(define-data-var protocol-fees-tk2 uint u0)
(define-data-var last-update-block uint u0)
(define-data-var pool-paused bool false)

;; Liquidity provider positions
(define-map lp-positions
    principal
    {
        lp-tokens: uint,
        tk1-supplied: uint,
        tk2-supplied: uint,
        last-update: uint,
        rewards-earned: uint
    }
)

;; Lending positions for TK1
(define-map tk1-loans
    principal
    {
        amount: uint,
        collateral-tk2: uint,
        interest-index: uint,
        last-update: uint
    }
)

;; Lending positions for TK2
(define-map tk2-loans
    principal
    {
        amount: uint,
        collateral-tk1: uint,
        interest-index: uint,
        last-update: uint
    }
)

;; Price oracle (simplified)
(define-map token-prices
    principal
    {
        price: uint, ;; Price in STX with 6 decimals
        last-update: uint
    }
)

;; Utilization tracking for lending optimization
(define-map utilization-history
    uint ;; block height
    {
        tk1-utilization: uint,
        tk2-utilization: uint,
        swap-volume: uint
    }
)

;; Helper functions

;; Simplified integer square root (approximation)
(define-private (sqrt (n uint))
    (if (<= n u1)
        n
        (if (<= n u4)
            u2
            (if (<= n u9)
                u3
                (if (<= n u16)
                    u4
                    (if (<= n u25)
                        u5
                        (if (<= n u36)
                            u6
                            (if (<= n u49)
                                u7
                                (if (<= n u64)
                                    u8
                                    (if (<= n u81)
                                        u9
                                        (if (<= n u100)
                                            u10
                                            ;; For larger numbers, use approximation
                                            (/ n u10)
                                        )
                                    )
                                )
                            )
                        )
                    )
                )
            )
        )
    )
)

;; Min function
(define-private (min (a uint) (b uint))
    (if (<= a b) a b)
)

;; Read-only functions

;; Get pool information
(define-read-only (get-pool-info)
    {
        tk1-reserve: (var-get pool-tk1),
        tk2-reserve: (var-get pool-tk2),
        total-lp-supply: (var-get total-lp-supply),
        tk1-borrowed: (var-get total-tk1-borrowed),
        tk2-borrowed: (var-get total-tk2-borrowed),
        tk1-available: (- (var-get pool-tk1) (var-get total-tk1-borrowed)),
        tk2-available: (- (var-get pool-tk2) (var-get total-tk2-borrowed)),
        tk1-utilization: (if (> (var-get pool-tk1) u0)
                            (/ (* (var-get total-tk1-borrowed) PRECISION) (var-get pool-tk1))
                            u0),
        tk2-utilization: (if (> (var-get pool-tk2) u0)
                            (/ (* (var-get total-tk2-borrowed) PRECISION) (var-get pool-tk2))
                            u0)
    }
)

;; Get LP position
(define-read-only (get-lp-position (user principal))
    (map-get? lp-positions user)
)

;; Get TK1 loan position
(define-read-only (get-tk1-loan (user principal))
    (map-get? tk1-loans user)
)

;; Get TK2 loan position
(define-read-only (get-tk2-loan (user principal))
    (map-get? tk2-loans user)
)

;; Calculate swap output (constant product formula)
(define-read-only (get-swap-output (token-in principal) (amount-in uint))
    (let (
        (reserve-in (if (is-eq token-in (as-contract tx-sender)) ;; TK1
                       (var-get pool-tk1)
                       (var-get pool-tk2)))
        (reserve-out (if (is-eq token-in (as-contract tx-sender)) ;; TK1
                        (var-get pool-tk2)
                        (var-get pool-tk1)))
        (amount-in-with-fee (- amount-in (/ (* amount-in SWAP-FEE) PRECISION)))
        (numerator (* amount-in-with-fee reserve-out))
        (denominator (+ reserve-in amount-in-with-fee))
    )
        (if (and (> reserve-in u0) (> reserve-out u0) (> amount-in u0))
            (ok (/ numerator denominator))
            ERR-INSUFFICIENT-LIQUIDITY
        )
    )
)

;; Calculate LP tokens for liquidity addition
(define-read-only (calculate-lp-tokens (tk1-amount uint) (tk2-amount uint))
    (let (
        (current-tk1 (var-get pool-tk1))
        (current-tk2 (var-get pool-tk2))
        (total-supply (var-get total-lp-supply))
    )
        (if (is-eq total-supply u0)
            ;; First liquidity provision
            (ok (- (sqrt (* tk1-amount tk2-amount)) MIN-LIQUIDITY))
            ;; Subsequent provisions
            (let (
                (lp-from-tk1 (/ (* tk1-amount total-supply) current-tk1))
                (lp-from-tk2 (/ (* tk2-amount total-supply) current-tk2))
            )
                (ok (min lp-from-tk1 lp-from-tk2))
            )
        )
    )
)

;; Calculate user's health factor for lending
(define-read-only (get-user-health-factor (user principal))
    (let (
        (tk1-loan (default-to {amount: u0, collateral-tk2: u0, interest-index: u0, last-update: u0}
                   (get-tk1-loan user)))
        (tk2-loan (default-to {amount: u0, collateral-tk1: u0, interest-index: u0, last-update: u0}
                   (get-tk2-loan user)))
        (tk1-debt (get amount tk1-loan))
        (tk2-debt (get amount tk2-loan))
        (tk1-collateral (get collateral-tk1 tk2-loan))
        (tk2-collateral (get collateral-tk2 tk1-loan))
        (total-collateral-value (+ tk1-collateral tk2-collateral)) ;; Simplified 1:1 pricing
        (total-debt-value (+ tk1-debt tk2-debt))
        (collateral-adjusted (* total-collateral-value LIQUIDATION-THRESHOLD))
    )
        (if (is-eq total-debt-value u0)
            (ok u999999999) ;; Max health factor if no debt
            (ok (/ (* collateral-adjusted PRECISION) total-debt-value))
        )
    )
)

;; Get current lending rates
(define-read-only (get-lending-rates)
    {
        tk1-rate: (var-get tk1-lending-rate),
        tk2-rate: (var-get tk2-lending-rate),
        last-update: (var-get last-update-block)
    }
)

;; Get protocol fees
(define-read-only (get-protocol-fees)
    {
        tk1-fees: (var-get protocol-fees-tk1),
        tk2-fees: (var-get protocol-fees-tk2)
    }
)

;; Public functions

;; Add liquidity to the pool
(define-public (add-liquidity (tk1-amount uint) (tk2-amount uint) (min-lp-tokens uint))
    (let (
        (lp-tokens (unwrap! (calculate-lp-tokens tk1-amount tk2-amount) ERR-INVALID-AMOUNT))
        (current-position (default-to {lp-tokens: u0, tk1-supplied: u0, tk2-supplied: u0, 
                                      last-update: u0, rewards-earned: u0}
                          (get-lp-position tx-sender)))
    )
        (asserts! (> tk1-amount u0) ERR-INVALID-AMOUNT)
        (asserts! (> tk2-amount u0) ERR-INVALID-AMOUNT)
        (asserts! (>= lp-tokens min-lp-tokens) ERR-SLIPPAGE-EXCEEDED)
        (asserts! (not (var-get pool-paused)) ERR-POOL-NOT-INITIALIZED)
        
        ;; Transfer tokens from user to contract
        (match (ft-transfer? TK1 tk1-amount tx-sender (as-contract tx-sender))
            success-tk1 (match (ft-transfer? TK2 tk2-amount tx-sender (as-contract tx-sender))
                success-tk2 (begin
                    ;; Update pool reserves
                    (var-set pool-tk1 (+ (var-get pool-tk1) tk1-amount))
                    (var-set pool-tk2 (+ (var-get pool-tk2) tk2-amount))
                    
                    ;; Mint LP tokens
                    (match (ft-mint? LP-TOKEN lp-tokens tx-sender)
                        mint-success (begin
                            ;; Update user position
                            (map-set lp-positions tx-sender {
                                lp-tokens: (+ (get lp-tokens current-position) lp-tokens),
                                tk1-supplied: (+ (get tk1-supplied current-position) tk1-amount),
                                tk2-supplied: (+ (get tk2-supplied current-position) tk2-amount),
                                last-update: stacks-block-height,
                                rewards-earned: (get rewards-earned current-position)
                            })
                            
                            ;; Update total supply
                            (var-set total-lp-supply (+ (var-get total-lp-supply) lp-tokens))
                            (var-set last-update-block stacks-block-height)
                            
                            (ok {lp-tokens: lp-tokens, tk1-amount: tk1-amount, tk2-amount: tk2-amount})
                        )
                        mint-error ERR-MINT-FAILED
                    )
                )
                error-tk2 ERR-TRANSFER-FAILED
            )
            error-tk1 ERR-TRANSFER-FAILED
        )
    )
)

;; Remove liquidity from the pool
(define-public (remove-liquidity (lp-tokens uint) (min-tk1 uint) (min-tk2 uint))
    (let (
        (current-position (unwrap! (get-lp-position tx-sender) ERR-INSUFFICIENT-BALANCE))
        (total-supply (var-get total-lp-supply))
        (tk1-amount (/ (* lp-tokens (var-get pool-tk1)) total-supply))
        (tk2-amount (/ (* lp-tokens (var-get pool-tk2)) total-supply))
    )
        (asserts! (> lp-tokens u0) ERR-INVALID-AMOUNT)
        (asserts! (>= (get lp-tokens current-position) lp-tokens) ERR-INSUFFICIENT-BALANCE)
        (asserts! (>= tk1-amount min-tk1) ERR-SLIPPAGE-EXCEEDED)
        (asserts! (>= tk2-amount min-tk2) ERR-SLIPPAGE-EXCEEDED)
        
        ;; Burn LP tokens
        (match (ft-burn? LP-TOKEN lp-tokens tx-sender)
            burn-success (begin
                ;; Transfer tokens back to user
                (match (as-contract (ft-transfer? TK1 tk1-amount tx-sender tx-sender))
                    transfer-tk1 (match (as-contract (ft-transfer? TK2 tk2-amount tx-sender tx-sender))
                        transfer-tk2 (begin
                            ;; Update pool reserves
                            (var-set pool-tk1 (- (var-get pool-tk1) tk1-amount))
                            (var-set pool-tk2 (- (var-get pool-tk2) tk2-amount))
                            
                            ;; Update user position
                            (map-set lp-positions tx-sender {
                                lp-tokens: (- (get lp-tokens current-position) lp-tokens),
                                tk1-supplied: (- (get tk1-supplied current-position) 
                                               (/ (* (get tk1-supplied current-position) lp-tokens) 
                                                  (get lp-tokens current-position))),
                                tk2-supplied: (- (get tk2-supplied current-position) 
                                               (/ (* (get tk2-supplied current-position) lp-tokens) 
                                                  (get lp-tokens current-position))),
                                last-update: stacks-block-height,
                                rewards-earned: (get rewards-earned current-position)
                            })
                            
                            ;; Update total supply
                            (var-set total-lp-supply (- total-supply lp-tokens))
                            
                            (ok {tk1-amount: tk1-amount, tk2-amount: tk2-amount})
                        )
                        error-tk2 ERR-TRANSFER-FAILED
                    )
                    error-tk1 ERR-TRANSFER-FAILED
                )
            )
            burn-error ERR-BURN-FAILED
        )
    )
)

;; Swap TK1 for TK2
(define-public (swap-tk1-for-tk2 (tk1-amount uint) (min-tk2-out uint))
    (let (
        (tk2-out (unwrap! (get-swap-output (as-contract tx-sender) tk1-amount) ERR-INSUFFICIENT-LIQUIDITY))
        (fee-amount (/ (* tk1-amount SWAP-FEE) PRECISION))
    )
        (asserts! (> tk1-amount u0) ERR-INVALID-AMOUNT)
        (asserts! (>= tk2-out min-tk2-out) ERR-SLIPPAGE-EXCEEDED)
        (asserts! (not (var-get pool-paused)) ERR-POOL-NOT-INITIALIZED)
        
        ;; Transfer TK1 from user to contract
        (match (ft-transfer? TK1 tk1-amount tx-sender (as-contract tx-sender))
            success (begin
                ;; Transfer TK2 from contract to user
                (match (as-contract (ft-transfer? TK2 tk2-out tx-sender tx-sender))
                    transfer-success (begin
                        ;; Update pool reserves
                        (var-set pool-tk1 (+ (var-get pool-tk1) tk1-amount))
                        (var-set pool-tk2 (- (var-get pool-tk2) tk2-out))
                        
                        ;; Update protocol fees
                        (var-set protocol-fees-tk1 (+ (var-get protocol-fees-tk1) fee-amount))
                        
                        ;; Update utilization tracking
                        (update-utilization-tracking tk1-amount)
                        
                        (ok {tk1-in: tk1-amount, tk2-out: tk2-out, fee: fee-amount})
                    )
                    transfer-error ERR-TRANSFER-FAILED
                )
            )
            error ERR-TRANSFER-FAILED
        )
    )
)

;; Swap TK2 for TK1
(define-public (swap-tk2-for-tk1 (tk2-amount uint) (min-tk1-out uint))
    (let (
        (tk1-out (unwrap! (get-swap-output (as-contract tx-sender) tk2-amount) ERR-INSUFFICIENT-LIQUIDITY))
        (fee-amount (/ (* tk2-amount SWAP-FEE) PRECISION))
    )
        (asserts! (> tk2-amount u0) ERR-INVALID-AMOUNT)
        (asserts! (>= tk1-out min-tk1-out) ERR-SLIPPAGE-EXCEEDED)
        (asserts! (not (var-get pool-paused)) ERR-POOL-NOT-INITIALIZED)
        
        ;; Transfer TK2 from user to contract
        (match (ft-transfer? TK2 tk2-amount tx-sender (as-contract tx-sender))
            success (begin
                ;; Transfer TK1 from contract to user
                (match (as-contract (ft-transfer? TK1 tk1-out tx-sender tx-sender))
                    transfer-success (begin
                        ;; Update pool reserves
                        (var-set pool-tk2 (+ (var-get pool-tk2) tk2-amount))
                        (var-set pool-tk1 (- (var-get pool-tk1) tk1-out))
                        
                        ;; Update protocol fees
                        (var-set protocol-fees-tk2 (+ (var-get protocol-fees-tk2) fee-amount))
                        
                        ;; Update utilization tracking
                        (update-utilization-tracking tk2-amount)
                        
                        (ok {tk2-in: tk2-amount, tk1-out: tk1-out, fee: fee-amount})
                    )
                    transfer-error ERR-TRANSFER-FAILED
                )
            )
            error ERR-TRANSFER-FAILED
        )
    )
)

;; Borrow TK1 against TK2 collateral
(define-public (borrow-tk1 (amount uint) (tk2-collateral uint))
    (let (
        (current-loan (default-to {amount: u0, collateral-tk2: u0, interest-index: u0, last-update: u0}
                      (get-tk1-loan tx-sender)))
        (max-borrow (/ (* tk2-collateral MAX-LTV) PRECISION))
        (new-total-borrow (+ (get amount current-loan) amount))
        (available-tk1 (- (var-get pool-tk1) (var-get total-tk1-borrowed)))
    )
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (asserts! (> tk2-collateral u0) ERR-INVALID-AMOUNT)
        (asserts! (<= new-total-borrow max-borrow) ERR-INSUFFICIENT-COLLATERAL)
        (asserts! (>= available-tk1 amount) ERR-INSUFFICIENT-LIQUIDITY)
        (asserts! (not (var-get pool-paused)) ERR-POOL-NOT-INITIALIZED)
        
        ;; Transfer TK2 collateral from user to contract
        (match (ft-transfer? TK2 tk2-collateral tx-sender (as-contract tx-sender))
            collateral-success (begin
                ;; Transfer TK1 loan to user
                (match (as-contract (ft-transfer? TK1 amount tx-sender tx-sender))
                    loan-success (begin
                        ;; Update user's loan position
                        (map-set tk1-loans tx-sender {
                            amount: new-total-borrow,
                            collateral-tk2: (+ (get collateral-tk2 current-loan) tk2-collateral),
                            interest-index: PRECISION,
                            last-update: stacks-block-height
                        })
                        
                        ;; Update protocol totals
                        (var-set total-tk1-borrowed (+ (var-get total-tk1-borrowed) amount))
                        
                        ;; Update lending rates
                        (update-lending-rates)
                        
                        (ok {borrowed: amount, collateral: tk2-collateral})
                    )
                    loan-error ERR-TRANSFER-FAILED
                )
            )
            collateral-error ERR-TRANSFER-FAILED
        )
    )
)

;; Borrow TK2 against TK1 collateral
(define-public (borrow-tk2 (amount uint) (tk1-collateral uint))
    (let (
        (current-loan (default-to {amount: u0, collateral-tk1: u0, interest-index: u0, last-update: u0}
                      (get-tk2-loan tx-sender)))
        (max-borrow (/ (* tk1-collateral MAX-LTV) PRECISION))
        (new-total-borrow (+ (get amount current-loan) amount))
        (available-tk2 (- (var-get pool-tk2) (var-get total-tk2-borrowed)))
    )
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (asserts! (> tk1-collateral u0) ERR-INVALID-AMOUNT)
        (asserts! (<= new-total-borrow max-borrow) ERR-INSUFFICIENT-COLLATERAL)
        (asserts! (>= available-tk2 amount) ERR-INSUFFICIENT-LIQUIDITY)
        (asserts! (not (var-get pool-paused)) ERR-POOL-NOT-INITIALIZED)
        
        ;; Transfer TK1 collateral from user to contract
        (match (ft-transfer? TK1 tk1-collateral tx-sender (as-contract tx-sender))
            collateral-success (begin
                ;; Transfer TK2 loan to user
                (match (as-contract (ft-transfer? TK2 amount tx-sender tx-sender))
                    loan-success (begin
                        ;; Update user's loan position
                        (map-set tk2-loans tx-sender {
                            amount: new-total-borrow,
                            collateral-tk1: (+ (get collateral-tk1 current-loan) tk1-collateral),
                            interest-index: PRECISION,
                            last-update: stacks-block-height
                        })
                        
                        ;; Update protocol totals
                        (var-set total-tk2-borrowed (+ (var-get total-tk2-borrowed) amount))
                        
                        ;; Update lending rates
                        (update-lending-rates)
                        
                        (ok {borrowed: amount, collateral: tk1-collateral})
                    )
                    loan-error ERR-TRANSFER-FAILED
                )
            )
            collateral-error ERR-TRANSFER-FAILED
        )
    )
)

;; Repay TK1 loan
(define-public (repay-tk1 (amount uint))
    (let (
        (current-loan (unwrap! (get-tk1-loan tx-sender) ERR-LOAN-NOT-FOUND))
        (repay-amount (if (> amount (get amount current-loan)) 
                         (get amount current-loan) 
                         amount))
        (collateral-to-return (/ (* repay-amount (get collateral-tk2 current-loan)) 
                                (get amount current-loan)))
    )
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (asserts! (> (get amount current-loan) u0) ERR-LOAN-NOT-FOUND)
        
        ;; Transfer TK1 repayment from user to contract
        (match (ft-transfer? TK1 repay-amount tx-sender (as-contract tx-sender))
            repay-success (begin
                ;; Return TK2 collateral to user
                (match (as-contract (ft-transfer? TK2 collateral-to-return tx-sender tx-sender))
                    collateral-success (begin
                        ;; Update user's loan position
                        (map-set tk1-loans tx-sender {
                            amount: (- (get amount current-loan) repay-amount),
                            collateral-tk2: (- (get collateral-tk2 current-loan) collateral-to-return),
                            interest-index: (get interest-index current-loan),
                            last-update: stacks-block-height
                        })
                        
                        ;; Update protocol totals
                        (var-set total-tk1-borrowed (- (var-get total-tk1-borrowed) repay-amount))
                        
                        ;; Update lending rates
                        (update-lending-rates)
                        
                        (ok {repaid: repay-amount, collateral-returned: collateral-to-return})
                    )
                    collateral-error ERR-TRANSFER-FAILED
                )
            )
            repay-error ERR-TRANSFER-FAILED
        )
    )
)

;; Repay TK2 loan
(define-public (repay-tk2 (amount uint))
    (let (
        (current-loan (unwrap! (get-tk2-loan tx-sender) ERR-LOAN-NOT-FOUND))
        (repay-amount (if (> amount (get amount current-loan)) 
                         (get amount current-loan) 
                         amount))
        (collateral-to-return (/ (* repay-amount (get collateral-tk1 current-loan)) 
                                (get amount current-loan)))
    )
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (asserts! (> (get amount current-loan) u0) ERR-LOAN-NOT-FOUND)
        
        ;; Transfer TK2 repayment from user to contract
        (match (ft-transfer? TK2 repay-amount tx-sender (as-contract tx-sender))
            repay-success (begin
                ;; Return TK1 collateral to user
                (match (as-contract (ft-transfer? TK1 collateral-to-return tx-sender tx-sender))
                    collateral-success (begin
                        ;; Update user's loan position
                        (map-set tk2-loans tx-sender {
                            amount: (- (get amount current-loan) repay-amount),
                            collateral-tk1: (- (get collateral-tk1 current-loan) collateral-to-return),
                            interest-index: (get interest-index current-loan),
                            last-update: stacks-block-height
                        })
                        
                        ;; Update protocol totals
                        (var-set total-tk2-borrowed (- (var-get total-tk2-borrowed) repay-amount))
                        
                        ;; Update lending rates
                        (update-lending-rates)
                        
                        (ok {repaid: repay-amount, collateral-returned: collateral-to-return})
                    )
                    collateral-error ERR-TRANSFER-FAILED
                )
            )
            repay-error ERR-TRANSFER-FAILED
        )
    )
)

;; Liquidate undercollateralized TK1 loan
(define-public (liquidate-tk1-loan (borrower principal) (repay-amount uint))
    (let (
        (borrower-loan (unwrap! (get-tk1-loan borrower) ERR-LOAN-NOT-FOUND))
        (health-factor (unwrap! (get-user-health-factor borrower) ERR-HEALTH-FACTOR-OK))
        (collateral-to-seize (/ (* repay-amount LIQUIDATION-BONUS) PRECISION))
    )
        (asserts! (> repay-amount u0) ERR-INVALID-AMOUNT)
        (asserts! (< health-factor PRECISION) ERR-HEALTH-FACTOR-OK)
        (asserts! (<= repay-amount (get amount borrower-loan)) ERR-INVALID-AMOUNT)
        (asserts! (<= collateral-to-seize (get collateral-tk2 borrower-loan)) ERR-INSUFFICIENT-COLLATERAL)
        
        ;; Transfer repayment from liquidator to contract
        (match (ft-transfer? TK1 repay-amount tx-sender (as-contract tx-sender))
            repay-success (begin
                ;; Transfer seized collateral to liquidator
                (match (as-contract (ft-transfer? TK2 collateral-to-seize tx-sender tx-sender))
                    seize-success (begin
                        ;; Update borrower's loan position
                        (map-set tk1-loans borrower {
                            amount: (- (get amount borrower-loan) repay-amount),
                            collateral-tk2: (- (get collateral-tk2 borrower-loan) collateral-to-seize),
                            interest-index: (get interest-index borrower-loan),
                            last-update: stacks-block-height
                        })
                        
                        ;; Update protocol totals
                        (var-set total-tk1-borrowed (- (var-get total-tk1-borrowed) repay-amount))
                        
                        (ok {repaid: repay-amount, seized: collateral-to-seize})
                    )
                    seize-error ERR-TRANSFER-FAILED
                )
            )
            repay-error ERR-TRANSFER-FAILED
        )
    )
)

;; Update lending rates based on utilization
(define-private (update-lending-rates)
    (let (
        (tk1-utilization (if (> (var-get pool-tk1) u0)
                            (/ (* (var-get total-tk1-borrowed) PRECISION) (var-get pool-tk1))
                            u0))
        (tk2-utilization (if (> (var-get pool-tk2) u0)
                            (/ (* (var-get total-tk2-borrowed) PRECISION) (var-get pool-tk2))
                            u0))
        (base-rate u20000) ;; 2%
        (multiplier u80000) ;; 8%
        (new-tk1-rate (+ base-rate (/ (* tk1-utilization multiplier) PRECISION)))
        (new-tk2-rate (+ base-rate (/ (* tk2-utilization multiplier) PRECISION)))
    )
        (var-set tk1-lending-rate new-tk1-rate)
        (var-set tk2-lending-rate new-tk2-rate)
        (var-set last-update-block stacks-block-height)
        true
    )
)

;; Update utilization tracking for optimization
(define-private (update-utilization-tracking (swap-volume uint))
    (let (
        (current-block stacks-block-height)
        (tk1-util (if (> (var-get pool-tk1) u0)
                     (/ (* (var-get total-tk1-borrowed) PRECISION) (var-get pool-tk1))
                     u0))
        (tk2-util (if (> (var-get pool-tk2) u0)
                     (/ (* (var-get total-tk2-borrowed) PRECISION) (var-get pool-tk2))
                     u0))
    )
        (map-set utilization-history current-block {
            tk1-utilization: tk1-util,
            tk2-utilization: tk2-util,
            swap-volume: swap-volume
        })
        true
    )
)

;; Admin functions

;; Initialize the pool (first time setup)
(define-public (initialize-pool (initial-tk1 uint) (initial-tk2 uint))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
        (asserts! (is-eq (var-get total-lp-supply) u0) ERR-POOL-NOT-INITIALIZED)
        (asserts! (> initial-tk1 u0) ERR-INVALID-AMOUNT)
        (asserts! (> initial-tk2 u0) ERR-INVALID-AMOUNT)
        
        ;; Transfer initial liquidity
        (match (ft-transfer? TK1 initial-tk1 tx-sender (as-contract tx-sender))
            success-tk1 (match (ft-transfer? TK2 initial-tk2 tx-sender (as-contract tx-sender))
                success-tk2 (begin
                    ;; Set initial reserves
                    (var-set pool-tk1 initial-tk1)
                    (var-set pool-tk2 initial-tk2)
                    
                    ;; Mint initial LP tokens (minus minimum liquidity)
                    (let ((initial-lp (- (sqrt (* initial-tk1 initial-tk2)) MIN-LIQUIDITY)))
                        (match (ft-mint? LP-TOKEN initial-lp tx-sender)
                            mint-success (begin
                                (var-set total-lp-supply initial-lp)
                                (var-set last-update-block stacks-block-height)
                                (ok initial-lp)
                            )
                            mint-error ERR-MINT-FAILED
                        )
                    )
                )
                error-tk2 ERR-TRANSFER-FAILED
            )
            error-tk1 ERR-TRANSFER-FAILED
        )
    )
)

;; Pause/unpause the pool
(define-public (set-pool-paused (paused bool))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
        (var-set pool-paused paused)
        (ok paused)
    )
)

;; Withdraw protocol fees
(define-public (withdraw-protocol-fees)
    (let (
        (tk1-fees (var-get protocol-fees-tk1))
        (tk2-fees (var-get protocol-fees-tk2))
    )
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
        
        (match (as-contract (ft-transfer? TK1 tk1-fees tx-sender tx-sender))
            transfer-tk1 (match (as-contract (ft-transfer? TK2 tk2-fees tx-sender tx-sender))
                transfer-tk2 (begin
                    (var-set protocol-fees-tk1 u0)
                    (var-set protocol-fees-tk2 u0)
                    (ok {tk1-fees: tk1-fees, tk2-fees: tk2-fees})
                )
                error-tk2 ERR-TRANSFER-FAILED
            )
            error-tk1 ERR-TRANSFER-FAILED
        )
    )
)

;; Mint LUKE governance tokens
(define-public (mint-luke (amount uint) (recipient principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (match (ft-mint? LUKE amount recipient)
            success (ok amount)
            error ERR-MINT-FAILED
        )
    )
)

;; Mint TK1 tokens (for testing)
(define-public (mint-tk1 (amount uint) (recipient principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (match (ft-mint? TK1 amount recipient)
            success (ok amount)
            error ERR-MINT-FAILED
        )
    )
)

;; Mint TK2 tokens (for testing)
(define-public (mint-tk2 (amount uint) (recipient principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (match (ft-mint? TK2 amount recipient)
            success (ok amount)
            error ERR-MINT-FAILED
        )
    )
)

;; Get LP token balance
(define-read-only (get-lp-balance (user principal))
    (ft-get-balance LP-TOKEN user)
)

;; Check if position is liquidatable
(define-read-only (is-liquidatable (user principal))
    (let (
        (health-factor (unwrap-panic (get-user-health-factor user)))
    )
        (< health-factor PRECISION)
    )
)