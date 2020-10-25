#' @import Rook
#' @importFrom parallel mclapply
#' @importFrom irlba irlba
#'
NULL

## Correct unloading of the library
.onUnload <- function (libpath) {
  library.dynam.unload("pagoda2", libpath)
}

# translate multilevel segmentation into a dendrogram, with the lowest level of the dendrogram listing the cells
multi2dend <- function(cl,counts,deep=F,dist='cor') {
  if(deep) {
    clf <- as.integer(cl$memberships[1,]); # take the lowest level
  } else {
    clf <- as.integer(membership(cl));
  }
  names(clf) <- names(membership(cl))
  clf.size <- unlist(tapply(clf,factor(clf,levels=seq(1,max(clf))),length))
  rowFac <- rep(NA,nrow(counts));
  rowFac[match(names(clf),rownames(counts))] <- clf;
  lvec <- colSumByFac(counts,rowFac)[-1,,drop=F];
  if(dist=='JS') {
    lvec.dist <- jsDist(t(lvec/pmax(1,Matrix::rowSums(lvec))));
  } else { # use correlation distance in log10 space
    lvec.dist <- 1-cor(t(log10(lvec/pmax(1,Matrix::rowSums(lvec))+1)))
  }
  d <- as.dendrogram(hclust(as.dist(lvec.dist),method='ward.D'))
  # add cell info to the laves
  addinfo <- function(l,env) {
    v <- as.integer(mget("index",envir=env,ifnotfound=0)[[1]])+1;
    attr(l,'nodeId') <- v
    assign("index",v,envir=env)
    attr(l,'nCells') <- sum(clf.size[as.integer(unlist(l))]);
    if(is.leaf(l)) {
      attr(l,'cells') <- names(clf)[clf==attr(l,'label')];
    }
    attr(l,'root') <- FALSE;
    return(l);
  }
  d <- dendrapply(d,addinfo,env=environment())
  attr(d,'root') <- TRUE;
  d
}


# quick utility to check if given character vector is colors
# thanks, Josh O'Brien: http://stackoverflow.com/questions/13289009/check-if-character-string-is-a-valid-color-representation
areColors <- function(x) {
  is.character(x) & sapply(x, function(X) {tryCatch(is.matrix(col2rgb(X)), error = function(e) FALSE)})
}

papply <- function(...,n.cores=detectCores(), mc.preschedule=FALSE) {
  if(n.cores>1) {
    if(requireNamespace("parallel", quietly = TRUE)) {
      return(mclapply(...,mc.cores=n.cores,mc.preschedule=mc.preschedule))
    } 
    
    if(requireNamespace("BiocParallel", quietly = TRUE)) { 
      # It should never happen because parallel is specified in Imports
      return(BiocParallel::bplapply(... , BPPARAM = BiocParallel::MulticoreParam(workers = n.cores)))
    }
  }

  # fall back on lapply
  lapply(...)
}

jw.disR <- function(x,y) {
  x <- x+1/length(x)/1e3;
  y <- y+1/length(y)/1e3;
  a <- x*log(x)  + y*log(y) - (x+y)*log((x+y)/2);
  sqrt(sum(a)/2)
}


# note transpose is meant to speed up calculations when neither scaling nor centering is required
fast.pca <- function(m,nPcs=2,tol=1e-10,scale=F,center=F,transpose=F) {
  if(transpose) {
    if(center) { m <- m-Matrix::rowMeans(m)}; if(scale) { m <- m/sqrt(Matrix::rowSums(m*m)); }
    a <- irlba(tcrossprod(m)/(ncol(m)-1), nu=0, nv=nPcs,tol=tol);
    a$l <- t(t(a$v) %*% m)
  } else {
    if(scale||center) { m <- scale(m,scale=scale,center=center) }
    #a <- irlba((crossprod(m) - nrow(m) * tcrossprod(Matrix::colMeans(m)))/(nrow(m)-1), nu=0, nv=nPcs,tol=tol);
    a <- irlba(crossprod(m)/(nrow(m)-1), nu=0, nv=nPcs,tol=tol);
    a$l <- m %*% a$v
  }
  a
}

val2col <- function(x,gradientPalette=NULL,zlim=NULL,gradient.range.quantile=0.95) {
  nx <- names(x);
  if(all(sign(x)>=0)) {
    if(is.null(gradientPalette)) {
      gradientPalette <- colorRampPalette(c('gray90','red'), space = "Lab")(1024)
    }
    if(is.null(zlim)) {
      zlim <- as.numeric(quantile(na.omit(x),p=c(1-gradient.range.quantile,gradient.range.quantile)))
      if(diff(zlim)==0) {
        zlim <- as.numeric(range(na.omit(x)))
      }
    }
    x[x<zlim[1]] <- zlim[1]; x[x>zlim[2]] <- zlim[2];
    x <- (x-zlim[1])/(zlim[2]-zlim[1])

  } else {
    if(is.null(gradientPalette)) {
      gradientPalette <- colorRampPalette(c("blue", "grey90", "red"), space = "Lab")(1024)
    }
    if(is.null(zlim)) {
      zlim <- c(-1,1)*as.numeric(quantile(na.omit(abs(x)),p=gradient.range.quantile))
      if(diff(zlim)==0) {
        zlim <- c(-1,1)*as.numeric(na.omit(max(abs(x))))
      }
    }
    x[x<zlim[1]] <- zlim[1]; x[x>zlim[2]] <- zlim[2];
    x <- (x-zlim[1])/(zlim[2]-zlim[1])

  }

  col <- gradientPalette[x*(length(gradientPalette)-1)+1]
  names(col) <- nx;
  col
}



# translate cell cluster dendrogram to an array, one row per node with 1/0 cluster membership
cldend2array <- function(d,cells=NULL) {
  if(is.null(cells)) { # figure out the total order of cells
    cells <- unlist(dendrapply(d,attr,'cells'))
  }
  getcellbin <- function(l) {
    if(is.leaf(l)) {
      vi <- match(attr(l,'cells'),cells)
      ra <- sparseMatrix(i=vi,p=c(0,length(vi)),x=rep(1,length(vi)),dims=c(length(cells),1),dimnames=list(NULL,attr(l,'nodeId')))
      return(ra);
    } else { # return rbind of the children arrays, plus your own
      ra <- do.call(cbind,lapply(l,getcellbin))
      ur <- unique(ra@i);
      ra <- cbind(sparseMatrix(ur+1,x=rep(1,length(ur)),p=c(0,length(ur)),dims=c(length(cells),1),dimnames=list(NULL,attr(l,'nodeId'))),ra);
      return(ra)
    }
  }
  a <- getcellbin(d)
  rownames(a) <- cells;
  return(t(a));
}


sn <- function(x) { names(x) <- x; return(x); }




#' @export show.app
show.app <- function(app, name, port, ip, browse = TRUE,  server = NULL) {
                                        # replace special characters
    name <- gsub("[^[:alnum:.]]", "_", name)

    if(is.null(server)) {
        server <- get.scde.server(port=port,ip=ip)
    }
    server$add(app = app, name = name)
    if(is.function(server$listenPort)) {
        url <- paste("http://", server$listenAddr, ":", server$listenPort(), server$appList[[name]]$path,"/index.html",sep='')
    } else {
        url <- paste("http://", server$listenAddr, ":", server$listenPort, server$appList[[name]]$path,"/index.html",sep='')
    }
    print(paste("app loaded at: ",url,sep=""))
    if(browse) {
        browseURL(url);
    }

    return(invisible(server))
}

# get SCDE server from saved session
get.scde.server <- function(port,ip) {
    if(exists("___scde.server", envir = globalenv())) {
        server <- get("___scde.server", envir = globalenv())
    } else {
        server <- Rook::Rhttpd$new()
        assign("___scde.server", server, envir = globalenv())
        if(!missing(ip)) {
            if(missing(port)) {
                server$start(listen = ip)
            } else {
                server$start(listen = ip, port = port)
            }
        } else {
            if(missing(port)) {
                server$start()
            } else {
                server$start(port=port)
            }
        }
    }
    return(server)
}

# BH P-value adjustment with a log option
bh.adjust <- function(x, log = FALSE) {
    nai <- which(!is.na(x))
    ox <- x
    x<-x[nai]
    id <- order(x, decreasing = FALSE)
    if(log) {
        q <- x[id] + log(length(x)/seq_along(x))
    } else {
        q <- x[id]*length(x)/seq_along(x)
    }
    a <- rev(cummin(rev(q)))[order(id)]
    ox[nai]<-a
    ox
}

# returns enriched categories for a given gene list as compared with a given universe
# returns a list with over and under fields containing list of over and underrepresented terms
calculate.go.enrichment <- function(genelist, universe, pvalue.cutoff = 1e-3, mingenes = 3, env = go.env, subset = NULL, list.genes = FALSE, over.only = FALSE) {
    genelist <- unique(genelist)
    all.genes <- unique(ls(env))
    # determine sizes
    universe <- unique(c(universe, genelist))
    universe <- universe[universe != ""]
    genelist <- genelist[genelist != ""]
    ns <- length(intersect(genelist, all.genes))
    us <- length(intersect(universe, all.genes))
    #pv <- lapply(go.map, function(gl) { nwb <- length(intersect(universe, gl[[1]])) if(nwb<mingenes) { return(0.5)} else { p <- phyper(length(intersect(genelist, gl[[1]])), nwb, us-nwb, ns) return(ifelse(p > 0.5, 1.0-p, p)) }})

    # compile count vectors
    stab <- table(unlist(mget(as.character(genelist), env, ifnotfound = NA), recursive = TRUE))
    utab <- table(unlist(mget(as.character(universe), env, ifnotfound = NA), recursive = TRUE))
    if(!is.null(subset)) {
        stab <- stab[names(stab) %in% subset]
        utab <- utab[names(utab) %in% subset]
    }

    tabmap <- match(rownames(stab), rownames(utab))

    cv <- data.frame(cbind(utab, rep(0, length(utab))))
    names(cv) <- c("u", "s")
    cv$s[match(rownames(stab), rownames(utab))] <- as.vector(stab)
    cv <- na.omit(cv)
    cv <- cv[cv$u > mingenes, ]

    if(over.only) {
        lpr <- phyper(cv$s-1, cv$u, us-cv$u, ns, lower.tail = FALSE, log.p = TRUE)
    } else {
        pv <- phyper(cv$s, cv$u, us-cv$u, ns, lower.tail = FALSE)
        lpr <- ifelse(pv<0.5, phyper(cv$s-1, cv$u, us-cv$u, ns, lower.tail = FALSE, log.p = TRUE), phyper(cv$s+1, cv$u, us-cv$u, ns, lower.tail = TRUE, log.p = TRUE))
    }
    lpr <- phyper(cv$s-1, cv$u, us-cv$u, ns, lower.tail = FALSE, log.p = TRUE)
    lpra <- bh.adjust(lpr, log = TRUE)
    z <- qnorm(lpr, lower.tail = FALSE, log.p = TRUE)
    za <- qnorm(lpra, lower.tail = FALSE, log.p = TRUE)
    # correct for multiple hypothesis
    mg <- length(which(cv$u > mingenes))
    if(over.only) {
        if(pvalue.cutoff<1) {
            ovi <- which(lpra<= log(pvalue.cutoff))
            uvi <- c()
        } else {
            ovi <- which((lpr+mg)<= log(pvalue.cutoff))
            uvi <- c()
        }
    } else {
        if(pvalue.cutoff<1) {
            ovi <- which(pv<0.5 & lpra<= log(pvalue.cutoff))
            uvi <- which(pv > 0.5 & lpra<= log(pvalue.cutoff))
        } else {
            ovi <- which(pv<0.5 & (lpr+mg)<= log(pvalue.cutoff))
            uvi <- which(pv > 0.5 & (lpr+mg)<= log(pvalue.cutoff))
        }
    }
    ovi <- ovi[order(lpr[ovi])]
    uvi <- uvi[order(lpr[uvi])]

    #return(list(over = data.frame(t = rownames(cv)[ovi], o = cv$s[ovi], u = cv$u[ovi], p = pr[ovi]*mg), under = data.frame(t = rownames(cv)[uvi], o = cv$s[uvi], u = cv$u[uvi], p = pr[uvi]*mg)))
    if(list.genes) {
        x <- mget(as.character(genelist), env, ifnotfound = NA)
        df <- data.frame(id = rep(names(x), unlist(lapply(x, function(d) length(na.omit(d))))), go = na.omit(unlist(x)), stringsAsFactors = FALSE)
        ggl <- tapply(df$id, as.factor(df$go), I)
        ovg <- as.character(unlist(lapply(ggl[rownames(cv)[ovi]], paste, collapse = " ")))
        uvg <- as.character(unlist(lapply(ggl[rownames(cv)[uvi]], paste, collapse = " ")))
        return(list(over = data.frame(t = rownames(cv)[ovi], o = cv$s[ovi], u = cv$u[ovi], Za = za, fe = cv$s[ovi]/(ns*cv$u[ovi]/us), genes = ovg), under = data.frame(t = rownames(cv)[uvi], o = cv$s[uvi], u = cv$u[uvi], Za = za, fe = cv$s[uvi]/(ns*cv$u[uvi]/us), genes = uvg)))
    } else {
        return(list(over = data.frame(t = rownames(cv)[ovi], o = cv$s[ovi], u = cv$u[ovi], p.raw = exp(lpr[ovi]), fdr = exp(lpra)[ovi], Z = z[ovi], Za = za[ovi], fe = cv$s[ovi]/(ns*cv$u[ovi]/us), fer = cv$s[ovi]/(length(genelist)*cv$u[ovi]/length(universe))), under = data.frame(t = rownames(cv)[uvi], o = cv$s[uvi], u = cv$u[uvi], p.raw = exp(lpr[uvi]), fdr = exp(lpra)[uvi], Z = z[uvi], Za = za[uvi], fe = cv$s[uvi]/(ns*cv$u[uvi]/us))))
    }
}

# fater matrix correlations wtih armadillo
#' @title armaCor - matrix column correlations
#' @description similar to cor() call, will calculate correlation between matrix columns
#' @param mat matrix, whose columns will be
#' @export armaCor
armaCor <- function(mat) {
  cd <- arma_mat_cor(mat);
  rownames(cd) <- colnames(cd) <- colnames(mat);
  return(cd)
}

#' Find the mode of a vector
#' @description return the mode of a vector
#' @param x the vector to return the mode of
#' @return the mode elements
Mode <- function(x) {
  ux <- unique(x)
  ux[which.max(tabulate(match(x, ux)))]
}


# load 10x matrices from a named list of result folders
##' Quick loading of 10X CellRanger text matrices
##'
##' @title Load 10X CellRanger count matrices
##' @param matrixPaths a single path to the folder containing matrix.mtx, genes.tsv and barcodes.tsv files, OR a named list of such paths
##' @param n.cores numebr of cores to utilize in parallel
##' @return a sparse matrix representation of the data (or a list of sparse matrices if a list of paths was passed)
##' @export
read.10x.matrices <- function(matrixPaths,n.cores=1,verbose=T) {
  if(length(matrixPaths)==1) {
    matrixPaths <- c('one'=matrixPaths);
    single.dataset <- TRUE;
  } else {
    single.dataset <- FALSE;
  }
  if(verbose) cat("reading",length(matrixPaths),"dataset(s) ")
  if(is.null(names(matrixPaths))) stop("matrixPaths must be a named vector")
  dl <- pagoda2:::papply(sn(names(matrixPaths)),function(nam) {

    matrixPath <- matrixPaths[nam];
    # read all count files (*_unique.counts) under a given path
    #cat("loading data from ",matrixPath, " ");
    fn <- paste(matrixPath,'matrix.mtx',sep='/');
    if(file.exists(fn)) {
      x <- as(readMM(fn),'dgCMatrix'); # convert to the required sparse matrix representation
    } else if(file.exists(paste(fn,'gz',sep='.'))) {
      x <- as(readMM(gzcon(file(paste(fn,'gz',sep='.'),'rb'))),'dgCMatrix'); # convert to the required sparse matrix representation
    } else {
      stop(paste('cant open',fn));
    }
    fn <- paste(matrixPath,'genes.tsv',sep='/');
    if(file.exists(paste(fn,'gz',sep='.'))) { fn <- paste(fn,'gz',sep='.') }
    gs <- read.delim(fn,header=F)
    rownames(x) <- gs[,2]    

    fn <- paste(matrixPath,'barcodes.tsv',sep='/');
    if(file.exists(paste(fn,'gz',sep='.'))) { fn <- paste(fn,'gz',sep='.') }
    gs <- read.delim(fn,header=F)
    colnames(x) <- gs[,1]

    if(verbose) cat(".")
    colnames(x) <- paste(nam,colnames(x),sep='_');
    x
  },n.cores=n.cores)
  if(verbose) cat(" done\n")
  if(single.dataset) { return(dl[[1]]); } else { return(dl) }
}



##' filter cells based on the gene/molecule dependency
##' @title Filter cells based on gene/molecule dependency
##' @param countMatrix input count matrix to be filtered
##' @param min.cell.size min allowed cell size (default 500)
##' @param max.cell.size max allowed cell size (default 5e4)
##' @param p.level statistical confidence level for deviation from the main trend, used for cell filtering
##' @param alpha shading of the confidence band
##' @param plot plot the molecule distribution and the gene/molecule dependency fit
##' @param do.par reset graphical parameters prior to plotting
##' @return a filtered matrix
##' @export
gene.vs.molecule.cell.filter <- function(countMatrix,min.cell.size=500, max.cell.size=5e4,p.level=min(1e-3,1/ncol(countMatrix)),alpha=0.1,plot=T, do.par=T) {
  if(plot) {
    if(do.par) { par(mfrow=c(1,2), mar = c(3.5,3.5,2.0,0.5), mgp = c(2,0.65,0), cex = 1.0);}
    hist(log10(colSums(countMatrix)),col='wheat',xlab='log10[ molecules ]',main='')
    # some of the cells are very large .. those can skew the analysis of more subtle populations (too much bias ) .. letting them in here though

    abline(v=log10(c(min.cell.size,max.cell.size)),lty=2,col=2)
  }
  # look at the number of genes vs. molecule size depenency
  df <- data.frame(molecules=colSums(countMatrix),genes=colSums(countMatrix>0));
  df <- df[df$molecules>=min.cell.size,];
  df <- log10(df);
  df <- df[order(df$molecules,decreasing=F),]
  if(plot) {
    plot(df,col=adjustcolor(1,alpha=alpha),cex=0.5,ylab='log10[ gene counts]',xlab='log10[ molecule counts]')
    abline(v=log10(c(min.cell.size,max.cell.size)),lty=2,col=2)
  }
  #abline(lm(genes ~ molecules, data=df),col=4)

  m <- MASS::rlm(genes~molecules,data=df)
  suppressWarnings(pb <- data.frame(predict(m,interval='prediction',level = 1-p.level,type="response")))
  outliers <- rownames(df)[df$genes > pb$upr | df$genes < pb$lwr];
  if(plot) {
    polygon(c(df$molecules,rev(df$molecules)),c(pb$lwr,rev(pb$upr)),col=adjustcolor(2,alpha=0.1),border = NA)
    points(df[outliers,],col=2,cex=0.6)
  }
  # set of filtered cells to move forward with
  valid.cells <- colSums(countMatrix)>min.cell.size & colSums(countMatrix)<max.cell.size & !(colnames(countMatrix) %in% outliers)
  countMatrix[,valid.cells,drop=F]
}

#' Get a vector of the names of an object named by the names themselves
#' @description Get a named vector of the names of an object. This is useful
#' with lapply when passing names of objects as it ensures that the output list
#' is also named
#' @param g an objects on which we can call names()
#' @export namedNames
namedNames <- function(g) {
  n <- names(g)
  names(n) <- n;
  n
}

embedKnnGraphUmap <- function(knn.graph, k=NULL, ...) {
  if (!requireNamespace("uwot", quietly=T))
    stop("You need to install package 'uwot' to be able to use UMAP embedding.")

  adj.mat <- igraph::as_adj(knn.graph, attr="weight") %>% as("dgTMatrix")
  vals.per.col <- split(setNames(adj.mat@x, adj.mat@i + 1), adj.mat@j + 1)
  nn <- sapply(vals.per.col, length);
  if(is.null(k)) k <- min(nn)

  if(k<3) stop("graph contains cells with fewer than 5 neighbors; please build a denser graph (increase k)")
  
  knns <- lapply(vals.per.col, function(x) sort(x, decreasing=T)[1:k])
  knn.ids <- sapply(knns, function(x) as.integer(names(x))) %>% t()
  knn.sims <- do.call(rbind, knns)
  knn.dists <- 1 - knn.sims / max(knn.sims)
  
  umap <- uwot::umap(data.frame(x=rep(0, nrow(knn.ids))), nn_method=list(idx=knn.ids, dist=knn.dists), ...)
  rownames(umap) <- colnames(adj.mat)
  return(umap)
}
