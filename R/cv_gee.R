cv_gee <- function (object, rule = c("all", "quadratic", "logarithmic", "spherical"), 
                    max_count = 500, K = 5L, M = 10L, seed = 1L, return_data = FALSE) {
    if (!inherits(object, "geeglm")) {
        stop("function 'cv_gee()' currently only works for 'geeglm' objects.")
    }
    rule <- match.arg(rule)
    predict_geeglm <- function (object, newdata) {
        Terms <- terms(object$model)
        mfX_new <- model.frame(Terms, newdata, 
                               xlev = .getXlevels(Terms, object$model))
        X <- model.matrix(Terms, mfX_new)
        betas <- coef(object)
        eta <- c(X %*% betas)
        resp <- model.response(mfX_new)
        n <- length(resp)
        max_count <- rep(max_count, length.out = n)
        if (object$family$family == "gaussian") {
            warning("the family of 'object' is 'gaussian'; argument 'rule'", 
                    " is set to 'quadratic'.")
            rule <- "quadratic"
            (resp - object$family$linkinv(eta))^2
        } else if (object$family$family == "binomial") {
            if (NCOL(resp) == 2) {
                N <- max_count <- resp[, 1] + resp[, 2]
                resp <- resp[, 1]
            } else {
                N <- max_count <- rep(1, n)
            }
            max_count_seq <- lapply(max_count, seq, from = 0)
            probs <- object$family$linkinv(eta)
            scale <- object$geese$gamma
            phi <- (N - scale) / (scale - 1)
            log_p_y <- dbbinom(x = resp, size = N, prob = probs, phi = phi, log = TRUE)
            quad_fun_binomial <- function (c1, c2, p, phi) {
              sum(exp(2 * dbbinom(x = c1, size = c2, prob = p, phi = phi, log = TRUE)))
            }
            quadrat_p <- mapply(quad_fun_binomial, c1 = max_count_seq, c2 = N, 
                                p = probs, phi = phi)
            switch(rule,
                   "all" = c(log_p_y, 2 * exp(log_p_y) - quadrat_p, 
                             exp(log_p_y - 0.5 * log(quadrat_p))),
                   "logarithmic" = log_p_y,
                   "quadratic" = 2 * exp(log_p_y) - quadrat_p, 
                   "spherical" = exp(log_p_y - 0.5 * log(quadrat_p)))
        } else if (object$family$family == "poisson") {
            counts <- object$family$linkinv(eta)
            scale <- object$geese$gamma
            shape_neg_bin <- counts / (scale - 1)
            log_p_y <- dnbinom(x = resp, size = shape_neg_bin, mu = counts, log = TRUE)
            max_count_seq <- lapply(max_count, seq, from = 0)
            quad_fun_poisson <- function (c1, c2, c3) {
                sum(exp(2 * dnbinom(x = c1, size = c2, mu = c3, log = TRUE)))
            }
            quadrat_p <- mapply(quad_fun_poisson, c1 = max_count_seq, c2 = shape_neg_bin,
                                c3 = counts)
            switch(rule,
                   "all" = c(log_p_y, 2 * exp(log_p_y) - quadrat_p, 
                             exp(log_p_y - 0.5 * log(quadrat_p))),
                   "logarithmic" = log_p_y,
                   "quadratic" = 2 * exp(log_p_y) - quadrat_p, 
                   "spherical" = exp(log_p_y - 0.5 * log(quadrat_p)))
        }
    }
    ##################################################
    if (!exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)) 
        runif(1)
    if (is.null(seed)) 
        RNGstate <- get(".Random.seed", envir = .GlobalEnv)
    else {
        R.seed <- get(".Random.seed", envir = .GlobalEnv)
        set.seed(seed)
        RNGstate <- structure(seed, kind = as.list(RNGkind()))
        on.exit(assign(".Random.seed", R.seed, envir = .GlobalEnv))
    }
    data <- object$data
    id <- object$id
    unq_id <- unique(id)
    n <- length(unq_id)
    mfX_orig <- model.frame(terms(formula(object)), data = data)
    if (!is.null(nas <- attr(mfX_orig, "na.action"))) {
      data <- data[-nas, ]
    }
    Q <- if (rule == "all") nrow(data) * 3 else nrow(data)
    out <- matrix(0.0, Q, M)
    for (m in seq_len(M)) {
        splits <- split(seq_len(n), sample(rep(seq_len(K), length.out = n)))
        for (i in seq_along(splits)) {
            id.i <- unq_id[splits[[i]]]
            train_data <- data[!id %in% id.i, ]
            test_data <- data[id %in% id.i, ]
            fit_i <- update(object, data = train_data)
            out[id %in% id.i, m] <- predict_geeglm(fit_i, test_data)
        }
    }
    scores <- rowMeans(out, na.rm = TRUE)
    if (return_data) {
        if (rule == "all") {
            data <- do.call('rbind', rep(list(data), 3))
            labs <- c("logarithmic", "quadratic", "spherical")
            data[[".rule"]] <- gl(3, nrow(data)/3, labels = labs)
        }
        data[[".score"]] <- scores
        data
    } else {
        if (rule == "all") {
            rules <- rep(c("logarithmic", "quadratic", "spherical"), each = nrow(data))
            split(scores, rules)
        } else {
            scores
        }
    }
}

dbbinom <- function (x, size, prob, phi, log = FALSE) {
  if (all(size == 1)) {
    return(dbinom(x, size, prob, log))
  }
  A <- prob * phi
  B <- phi * (1 - prob)
  log_numerator <- lbeta(x + A, size - x + B)
  log_denominator <- lbeta(A, B)
  fact <- lchoose(size, x)
  if (log) {
    fact + log_numerator - log_denominator
  } else {
    exp(fact + log_numerator - log_denominator)
  }
}

predict.geeglm <- function (object, newdata, type = c("link", "response"),
                            se.fit = FALSE, ...) {
  type <- match.arg(type)
  Terms <- terms(object$model)
  mfX_new <- model.frame(Terms, newdata, 
                         xlev = .getXlevels(Terms, object$model))
  X <- model.matrix(Terms, mfX_new)
  betas <- coef(object)
  eta <- c(X %*% betas)
  if (!se.fit) {
    if (type == "link") eta else object$family$linkinv(eta)
  } else {
    list(fit = if (type == "link") eta else object$family$linkinv(eta),
         se.fit = sqrt(diag(X %*% tcrossprod(object$geese$vbeta, X))))
  }
}


