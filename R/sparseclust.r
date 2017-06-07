#' @useDynLib pagoda2
#' @import GO.db
#' @import org.Hs.eg.db
#' @import MASS
#' @import Matrix
#' @importFrom Rcpp evalCpp
#' @import Rook
#' @import igraph
#' @importFrom irlba irlba
#' @import pcaMethods
#' @importFrom mgcv gam
#' @importFrom parallel mclapply
# @importFrom scde pagoda.reduce.loading.redundancy pagoda.reduce.redundancy
#' @importFrom RMTstat WishartMaxPar
#' @importFrom Rcpp sourceCpp
NULL

sn <- function(x) { names(x) <- x; return(x); }

#' @export Pagoda2
#' @exportClass Pagoda2
Pagoda2 <- setRefClass(
  "Pagoda2",
  fields=c('counts','clusters','graphs','reductions','embeddings','diffgenes','pathways','n.cores','misc','batch','modelType','verbose','depth','batchNorm','mat'),
  methods = list(
    initialize=function(x, ..., modelType='plain',batchNorm='glm',n.cores=30,verbose=TRUE,min.cells.per.gene=30,trim=round(min.cells.per.gene/2),lib.sizes=NULL,log.scale=FALSE) {
      # # init all the output lists
      embeddings <<- list();
      graphs <<- list();
      diffgenes <<- list();
      reductions <<-list();
      clusters <<- list();
      pathways <<- list()
      misc <<-list(lib.sizes=lib.sizes,log.scale=log.scale,model.type=modelType,trim=trim);
      batch <<- NULL;
      counts <<- NULL;
      if(!missing(x) && class(x)=='Pagoda2') {
        callSuper(x, ..., modelType=modelType, batchNorm=batchNorm, n.cores=n.cores);
      } else {
        callSuper(..., modelType=modelType, batchNorm=batchNorm, n.cores=n.cores,verbose=verbose);
        if(!missing(x) && is.null(counts)) { # interpret x as a countMatrix
          setCountMatrix(x,min.cells.per.gene=min.cells.per.gene,trim=trim,lib.sizes=lib.sizes,log.scale=log.scale)
        }
      }
    },
    # provide the initial count matrix, and estimate deviance residual matrix (correcting for depth and batch)
    setCountMatrix=function(countMatrix,depthScale=1e3,min.cells.per.gene=30,trim=round(min.cells.per.gene/2),lib.sizes=NULL,log.scale=FALSE) {
      # check names
      if(any(duplicated(rownames(countMatrix)))) {
        stop("duplicate gene names are not allowed - please reduce")
      }
      if(any(duplicated(colnames(countMatrix)))) {
        stop("duplicate cell names are not allowed - please reduce")
      }

      if(!is.null(batch)) {
        if(!all(colnames(countMatrix) %in% names(batch))) { stop("the supplied batch vector doesn't contain all the cells in its names attribute")}
        colBatch <- as.factor(batch[colnames(countMatrix)])
        batch <<- colBatch;
      }

      if(!is.null(lib.sizes)) {
        if(!all(colnames(countMatrix) %in% names(lib.sizes))) { stop("the supplied lib.sizes vector doesn't contain all the cells in its names attribute")}
        lib.sizes <- lib.sizes[colnames(countMatrix)]
      }

      # determine deviance matrix
      if(!is.null(lib.sizes)) {
        depth <<- lib.sizes/mean(lib.sizes)*mean(Matrix::colSums(countMatrix))
      } else {
        depth <<- Matrix::colSums(countMatrix);
      }

      counts <<- t(countMatrix)
      counts <<- counts[,diff(counts@p)>min.cells.per.gene]

      misc[['rawCounts']] <<- counts;

      cat(nrow(counts),"cells,",ncol(counts),"genes; normalizing ... ")
      # get normalized matrix
      if(modelType=='linearObs') { # this shoudln't work well, since the depth dependency is not completely normalized out

        # winsorize in normalized space first in hopes of getting a more stable depth estimate
        if(trim>0) {
          counts <<- counts/as.numeric(depth);
          inplaceWinsorizeSparseCols(counts,trim);
          counts <<- counts*as.numeric(depth);
          if(is.null(lib.sizes)) {
            depth <<- round(Matrix::rowSums(counts))
          }
        }


        ldepth <- log(depth);

        # rank cells, cut into n pieces
        n.depth.slices <- 20;
        #depth.fac <- as.factor(floor(rank(depth)/(length(depth)+1)*n.depth.slices)+1); names(depth.fac) <- rownames(counts);
        depth.fac <- cut(cumsum(sort(depth)),breaks=seq(0,sum(depth),length.out=n.depth.slices)); names(depth.fac) <- rownames(counts);
        depth.fac <- depth.fac[rank(depth)]
        # dataset-wide gene average
        gene.av <- (Matrix::colSums(counts)+n.depth.slices)/(sum(depth)+n.depth.slices)

        # pooled counts, df for all genes
        tc <- colSumByFac(counts,as.integer(depth.fac))[-1,,drop=F]
        tc <- log(tc+1)- log(as.numeric(tapply(depth,depth.fac,sum))+1)
        md <- log(as.numeric(tapply(depth,depth.fac,mean)))
        # combined lm
        cm <- lm(tc ~ md)
        colnames(cm$coef) <- colnames(counts)
        # adjust counts
        # predict log(p) for each non-0 entry
        count.gene <- rep(1:counts@Dim[2],diff(counts@p))
        exp.x <- exp(log(gene.av)[count.gene] - cm$coef[1,count.gene] - ldepth[counts@i+1]*cm$coef[2,count.gene])
        counts@x <<- counts@x*exp.x/(depth[counts@i+1]/depthScale); # normalize by depth as well
        # performa another round of trim
        if(trim>0) {
          inplaceWinsorizeSparseCols(counts,trim);
        }


        # regress out on non-0 observations of ecah gene
        #non0LogColLmS(counts,mx,ldepth)
      } else if(modelType=='plain') {
        cat("using plain model ")

        if(!is.null(batch)) {
          cat("batch ... ")

          # dataset-wide gene average
          gene.av <- (Matrix::colSums(counts)+length(levels(batch)))/(sum(depth)+length(levels(batch)))

          # pooled counts, df for all genes
          tc <- colSumByFac(counts,as.integer(batch))[-1,,drop=F]
          tc <- t(log(tc+1)- log(as.numeric(tapply(depth,batch,sum))+1))
          bc <- exp(tc-log(gene.av))

          # adjust every non-0 entry
          count.gene <- rep(1:counts@Dim[2],diff(counts@p))
          counts@x <<- counts@x/bc[cbind(count.gene,as.integer(batch)[counts@i+1])]
        }

        if(trim>0) {
          cat("winsorizing ... ")
          counts <<- counts/as.numeric(depth);
          inplaceWinsorizeSparseCols(counts,trim);
          counts <<- counts*as.numeric(depth);
          if(is.null(lib.sizes)) {
            depth <<- round(Matrix::rowSums(counts))
          }
        }

        counts <<- counts/(depth/depthScale);
        #counts@x <<- log10(counts@x+1)
      } else {
        stop('modelType ',modelType,' is not implemented');
      }
      if(log.scale) {
        cat("log scale ... ")
        counts@x <<- log(counts@x+1)
      }
      misc[['rescaled.mat']] <<- NULL;
      cat("done.\n")
    },

    # adjust variance of the residual matrix, determine overdispersed sites
    adjustVariance=function(gam.k=5, alpha=5e-2, plot=FALSE, use.unadjusted.pvals=FALSE,do.par=T,max.adjusted.variance=1e3,min.adjusted.variance=1e-3,cells=NULL,verbose=TRUE,min.gene.cells=0,persist=is.null(cells)) {
      #persist <- is.null(cells) # persist results only if variance normalization is performed for all cells (not a subset)
      if(!is.null(cells)) { # translate cells into a rowSel boolean vector
        if(!(is.logical(cells) && length(cells)==nrow(counts))) {
          if(is.character(cells) || is.integer(cells)) {
            rowSel <- rep(FALSE,nrow(counts)); names(rowSel) <- rownames(counts); rowSel[cells] <- TRUE;
          } else {
            stop("cells argument must be either a logical vector over rows of the count matrix (cells), a vector of cell names or cell integer ids (row numbers)");
          }
        }
      } else {
        rowSel <- NULL;
      }

      if(verbose) cat("calculating variance fit ...")
      df <- colMeanVarS(counts,rowSel);

      df$m <- log(df$m); df$v <- log(df$v);
      rownames(df) <- colnames(counts);
      vi <- which(is.finite(df$v) & df$nobs>=min.gene.cells);
      if(length(vi)<gam.k*1.5) { gam.k=1 };# too few genes
      if(gam.k<2) {
        if(verbose) cat(" using lm ")
        m <- lm(v ~ m, data = df[vi,])
      } else {
        if(verbose) cat(" using gam ")
        require(mgcv)
        formul <- as.formula(v~s(m,k=gam.k))
        eformul <- new.env(parent=as.environment("package:mgcv"))
        assign("gam.k",gam.k,envir=eformul)
        environment(formul) <- eformul
        m <- mgcv::gam(formula=formul,data=df[vi,])
      }
      df$res <- -Inf;  df$res[vi] <- resid(m,type='response')
      n.obs <- df$nobs; #diff(counts@p)
      df$lp <- as.numeric(pf(exp(df$res),n.obs,n.obs,lower.tail=F,log.p=T))
      df$lpa <- bh.adjust(df$lp,log=TRUE)
      n.cells <- nrow(counts)
      df$qv <- as.numeric(qchisq(df$lp, n.cells-1, lower.tail = FALSE,log.p=TRUE)/n.cells)

      if(use.unadjusted.pvals) {
        ods <- which(df$lp<log(alpha))
      } else {
        ods <- which(df$lpa<log(alpha))
      }
      if(verbose) cat(length(ods),'overdispersed genes ... ' )
      if(persist) misc[['odgenes']] <<- rownames(df)[ods];

      df$gsf <- geneScaleFactors <- sqrt(pmax(min.adjusted.variance,pmin(max.adjusted.variance,df$qv))/exp(df$v));
      df$gsf[!is.finite(df$gsf)] <- 0;

      if(persist) {
        if(verbose) cat(length(ods),'persisting ... ' )
        misc[['varinfo']] <<- df;
      }

      # rescale mat variance
      ## if(rescale.mat) {
      ##   if(verbose) cat("rescaling signal matrix ... ")
      ##   #df$gsf <- geneScaleFactors <- sqrt(1/exp(df$v));
      ##   inplaceColMult(counts,geneScaleFactors,rowSel);  # normalize variance of each gene
      ##   #inplaceColMult(counts,rep(1/mean(Matrix::colSums(counts)),ncol(counts))); # normalize the column sums to be around 1
      ##   if(persist) misc[['rescaled.mat']] <<- geneScaleFactors;
      ## }
      if(plot) {
        if(do.par) {
          par(mfrow=c(1,2), mar = c(3.5,3.5,2.0,0.5), mgp = c(2,0.65,0), cex = 1.0);
        }
        smoothScatter(df$m,df$v,main='',xlab='log10[ magnitude ]',ylab='log10[ variance ]')
        grid <- seq(min(df$m[vi]),max(df$m[vi]),length.out=1000)
        lines(grid,predict(m,newdata=data.frame(m=grid)),col="blue")
        if(length(ods)>0) {
          points(df$m[ods],df$v[ods],pch='.',col=2,cex=1)
        }
        smoothScatter(df$m[vi],df$qv[vi],xlab='log10[ magnitude ]',ylab='',main='adjusted')
        abline(h=1,lty=2,col=8)
        if(is.finite(max.adjusted.variance)) { abline(h=max.adjusted.variance,lty=2,col=1) }
        points(df$m[ods],df$qv[ods],col=2,pch='.')
      }
      if(verbose) cat("done.\n")
      return(invisible(df));
    },
    # make a Knn graph
    # note: for reproducibility, set.seed() and set n.cores=1
    makeKnnGraph=function(k=30,nrand=1e3,type='counts',weight.type='none',odgenes=NULL,n.cores=.self$n.cores,distance='cosine',center=TRUE,x=NULL,verbose=TRUE,p=NULL) {
      require(igraph)
      if(is.null(x)) {
        x.was.given <- FALSE;
        if(type=='counts') {
          x <- counts;
        } else {
          if(type %in% names(reductions)) {
            x <- reductions[[type]];
          }
        }
        if(!is.null(odgenes)) {
          if(!all(odgenes %in% rownames(x))) { warning("not all of the provided odgenes are present in the selected matrix")}
          if(verbose) cat("using provided odgenes ... ")
          x <- x[,odgenes]
        }

        # apply scaling if using raw counts
        if(type=='counts') {
          #x <- t(t(x)*misc[['varinfo']][colnames(x),'gsf'])
          x@x <- x@x*rep(misc[['varinfo']][colnames(x),'gsf'],diff(x@p))
        }

      } else {
        x.was.given <- TRUE;
      }

      # TODO: enable sparse matrix support for hnsKnn2

      if(distance=='cosine') {
        if(center) {
          x<- x - Matrix::rowMeans(x) # centering for consine distance
        }
        xn <- hnswKnn2(x,k,nThreads=n.cores,verbose=verbose)
      } else if(distance=='JS') {
        x <- x/pmax(1,Matrix::rowSums(x));
        xn <- hnswKnnJS(x,k,nThreads=n.cores)
      } else if(distance=='L2') {
        xn <- hnswKnnLp(x,k,nThreads=n.cores,p=2.0,verbose=verbose)
      } else if(distance=='L1') {
        xn <- hnswKnnLp(x,k,nThreads=n.cores,p=1.0,verbose=verbose)
      } else if(distance=='Lp') {
        if(is.null(p)) stop("p argument must be provided when using Lp distance")
        xn <- hnswKnnLp(x,k,nThreads=n.cores,p=p,verbose=verbose)
      } else {
        stop("unknown distance measure specified")
      }
      if(weight.type=='rank') {
        xn$r <-  unlist(lapply(diff(c(0,which(diff(xn$s)>0),nrow(xn))),function(x) seq(x,1)))
      }
      xn <- xn[!xn$s==xn$e,]

      if(n.cores==1) { # for reproducibility, sort by node names
        if(verbose) cat("ordering neighbors for reproducibility ... ");
        xn <- xn[order(xn$s+xn$e),]
        if(verbose) cat("done\n");
      }
      df <- data.frame(from=rownames(x)[xn$s+1],to=rownames(x)[xn$e+1],weight=xn$d,stringsAsFactors=F)
      if(weight.type=='rank') { df$rank <- xn$r }
      if(weight.type %in% c("cauchy","normal") && ncol(x)>sqrt(nrand)) {
        # generate some random pair data for scaling
        if(distance=='cosine') {
          #rd <- na.omit(apply(cbind(sample(colnames(x),nrand,replace=T),sample(colnames(x),nrand,replace=T)),1,function(z) if(z[1]==z[2]) {return(NA); } else {1-cor(x[,z[1]],x[,z[2]])}))
          rd <- na.omit(apply(cbind(sample(colnames(x),nrand,replace=T),sample(colnames(x),nrand,replace=T)),1,function(z) if(z[1]==z[2]) {return(NA); } else {1-sum(x[,z[1]]*x[,z[2]])/sqrt(sum(x[,z[1]]^2)*sum(x[,z[2]]^2))}))
        } else if(distance=='JS') {
          rd <- na.omit(apply(cbind(sample(colnames(x),nrand,replace=T),sample(colnames(x),nrand,replace=T)),1,function(z) if(z[1]==z[2]) {return(NA); } else {jw.disR(x[,z[1]],x[,z[2]])}))
        } else if(distance=='L2') {
          rd <- na.omit(apply(cbind(sample(colnames(x),nrand,replace=T),sample(colnames(x),nrand,replace=T)),1,function(z) if(z[1]==z[2]) {return(NA); } else {sqrt(sum((x[,z[1]]-x[,z[2]])^2))}))
        } else if(distance=='L1') {
          rd <- na.omit(apply(cbind(sample(colnames(x),nrand,replace=T),sample(colnames(x),nrand,replace=T)),1,function(z) if(z[1]==z[2]) {return(NA); } else {sum(abs(x[,z[1]]-x[,z[2]]))}))
        }
        suppressWarnings(rd.model <- fitdistr(rd,weight.type))
        if(weight.type=='cauchy') {
          df$weight <- 1/pcauchy(df$weight,location=rd.model$estimate['location'],scale=rd.model$estimate['scale'])-1
        } else {
          df$weight <- 1/pnorm(df$weight,mean=rd.model$estimate['mean'],sd=rd.model$estimate['sd'])-1
        }
      }
      df$weight <- pmax(0,df$weight);
      if(weight.type=='constant') { df$weight <- 1}
      if(weight.type=='rank') { df$weight <- sqrt(df$rank) };
      # make a weighted edge matrix for the largeVis as well
      if(x.was.given) {
        return(invisible(as.undirected(graph.data.frame(df))))
      } else {
        misc[['edgeMat']][[type]] <<- cbind(xn,rd=df$weight);
        g <- as.undirected(graph.data.frame(df))
        graphs[[type]] <<- g;
      }
    },
    # calculate KNN-based clusters
    getKnnClusters=function(type='counts',method=multilevel.community, name='community', test.stability=FALSE, subsampling.rate=0.8, n.subsamplings=10, cluster.stability.threshold=0.95, n.cores=.self$n.cores, g=NULL, metaclustering.method='ward.D', min.cluster.size=2, persist=TRUE, plot=FALSE, return.details=FALSE, ...) {
      if(is.null(g)) {
        if(is.null(graphs[[type]])) { stop("call makeKnnGraph(type='",type,"', ...) first")}
        g <- graphs[[type]];
      }

      if(is.null(method)) {
        if(length(vcount(g))<2000) {
          method <- infomap.community;
        } else {
          method <- multilevel.community;
        }
      }

      # method <- multilevel.community; n.cores <- 20
      # n.subsamplings <- 10; cluster.stability.dilution <- 1.5; cluster.stability.fraction <- 0.9; subsampling.rate <- 0.8; metaclustering.method<- 'ward.D'
      # g <- r$graphs$PCA
      # x <- r$counts
      # cls <- method(g)

      #library(parallel)
      #x <- mclapply(1:5,function(z) method(g),mc.cores=20)

      cls <- method(g,...)
      cls.groups <- as.factor(membership(cls));


      if(test.stability) {
        # cleanup the clusters to remove very small ones
        cn <- names(cls.groups);
        vg <- which(unlist(tapply(cls.groups,cls.groups,length))>=min.cluster.size);
        cls.groups <- as.integer(cls.groups); cls.groups[!cls.groups %in% vg] <- NA;
        cls.groups <- as.factor(cls.groups);
        names(cls.groups) <- cn;
        # is there more than one cluster?
        if(length(levels(cls.groups))>1) {
          # run subsamplings
          cls.cells <- tapply(1:length(cls.groups),cls.groups,I)

          # if(type=='counts') {
          #   x <- counts;
          # } else {
          #   if(!type %in% names(reductions)) { stop("reduction ",type,' not found')}
          #   x <- reductions[[type]]
          # }
          #x <- counts;
          hcd <- multi2dend(cls,misc[['rawCounts']])
          m1 <- cldend2array(hcd);

          ai <- do.call(cbind,mclapply(1:n.subsamplings,function(i) {
            sg <- g;
            vi <- sample(1:vcount(sg),round(vcount(sg)*(1-subsampling.rate)))
            sg <- delete.vertices(sg,vi)
            scls <- method(sg)
            m2 <- cldend2array(multi2dend(scls,misc[['rawCounts']]))
            m1s <- m1[,colnames(m2)]
            ai <- (m1s %*% t(m2));
            ai <- ai/(outer(Matrix::rowSums(m1s),Matrix::rowSums(m2),"+") - ai)
            ns <- apply(ai,1,max)
          },mc.cores=n.cores))
          stevl <- apply(ai,1,mean); # node stability measure

          require(dendextend)
          hcd <- hcd %>% set("nodes_pch",19) %>% set("nodes_cex",3) %>% set("nodes_col",val2col(stevl,zlim=c(0.9,1)))


          # annotate n cells on the dednrogram
          t.find.biggest.stable.split <- function(l,env=environment()) {
            if(is.leaf(l)) { return(FALSE) } # don't report stable leafs ?
            bss <- mget("biggest.stable.split.size",envir=env,ifnotfound=-1)[[1]]
            if(attr(l,'nCells') <= bss) { return(FALSE) }

            # test current split for stability
            if(min(stevl[unlist(lapply(l,attr,'nodeId'))]) >= cluster.stability.threshold) { # stable
              # record size
              assign("biggest.stable.split.size",attr(l,'nCells'),envir=env)
              assign("biggest.stable.split",l,envir=env)
              return(TRUE);
            } else {
              # look within
              #return(na.omit(unlist(c(t.find.biggest.stable.split,env=env),recursive=F)))
              return(lapply(l,t.find.biggest.stable.split,env=env))
            }
          }
          # find biggest stable cell split
          e <- environment()
          bss.found <- any(unlist(t.find.biggest.stable.split(hcd,e)));
          if(bss.found) {
            # a stable split was found
            bss <- get('biggest.stable.split',envir=e)
            bss.par <- attr(bss,'nodesPar'); bss.par$col <- 'blue'; attr(bss,'nodesPar') <- bss.par;

            # find all untinterrupted stable subsplits
            consecutiveStableSubleafs <- function(l) {
              if(is.leaf(l) || min(stevl[unlist(lapply(l,attr,'nodeId'))]) < cluster.stability.threshold) {
                # either leaf or not sitting on top of a stable split - return own factor
                return(paste(unlist(l),collapse='+'));
              } else {
                # if both children are stable, return combination of their returns
                return(lapply(l,consecutiveStableSubleafs))
              }
            }
            stable.clusters <- unlist(consecutiveStableSubleafs(bss))


            final.groups <- rep("other", length(cls.groups));
            cf <- rep("other",length(cls.cells));
            for(k in stable.clusters) {
              ci <- as.integer(unlist(strsplit(k,'\\+')));
              final.groups[unlist(cls.cells[ci])] <- k;
              cf[ci] <- k;
            }
            final.groups <- as.factor(final.groups); names(final.groups) <- names(cls.groups);

            hcd <- hcd %>% branches_attr_by_clusters(clusters=as.integer(as.factor(cf[order.dendrogram(hcd)]))) %>% set("branches_lwd", 3)

          } else {
            # TODO: check for any stable node, report that

            final.groups <- rep(1, length(cls.groups)); names(final.groups) <- names(cls.groups);
          }

          #TODO: clean up cell-cluster assignment based on the pooled cluster data

          if(plot) {
            #.self$plotEmbedding(type='PCA',groups=cls.groups,show.legend=T)
            par(mar = c(3.5,3.5,2.0,0.5), mgp = c(2,0.65,0), cex = 1.0);
            hcd %>% plot();
            z <- get_nodes_xy(hcd); text(z,labels=round(stevl,2),adj=c(0.4,0.4),cex=0.7)
          }

          # return details

          rl <- list(groups=final.groups,"original.groups"=cls.groups,'hcd'=hcd,"stevl"=stevl,"cls"=cls)
          if(persist) {
            clusters[[type]][[name]] <<- final.groups;
            misc[['community']][[type]][[name]] <<- rl;
          }
          if(return.details) { return(invisible(rl))}
          return(invisible(final.groups))
        } # end: more than one group
        return(invisible(cls.groups))
      }
      if(persist) {
        clusters[[type]][[name]] <<- cls.groups;
        misc[['community']][[type]][[name]] <<- cls;
      }
      return(invisible(cls))
    },

    # calculate density-based clusters
    getDensityClusters=function(type='counts', embeddingType=NULL, name='density', v=0.7, s=1, ...) {
      if(is.null(embeddings[[type]])) { stop("first, generate embeddings for type ",type)}
      if(is.null(embeddingType)) {
        # take the first one
        embeddingType <- names(embeddings[[type]])[1]
        cat("using",embeddingType,"embedding\n")
        emb <- embeddings[[type]][[embeddingType]]

      } else {
        emb <- embeddings[[type]][[embeddingType]]
        if(is.null(emb)) { stop("embedding ",embeddingType," for type ", type," doesn't exist")}
      }
      require(dbscan)
      cl <- dbscan::dbscan(emb, ...)$cluster;
      cols <- rainbow(length(unique(cl)),v=v,s=s)[cl+1];    cols[cl==0] <- "gray70"
      names(cols) <- rownames(emb);
      clusters[[type]][[name]] <<- cols;
      misc[['clusters']][[type]][[name]] <<- cols;
      return(invisible(cols))
    },
    # determine subpopulation-specific genes
    getDifferentialGenes=function(type='counts',clusterType=NULL,groups=NULL,name='customClustering', z.threshold=3,upregulated.only=FALSE,verbose=FALSE) {
      # restrict counts to the cells for which non-NA value has been specified in groups

      if(is.null(groups)) {
        # look up the clustering based on a specified type
        if(is.null(clusterType)) {
          # take the first one
          cols <- clusters[[type]][[1]]
        } else {
          cols <- clusters[[type]][[clusterType]]
          if(is.null(cols)) { stop("clustering ",clusterType," for type ", type," doesn't exist")}
        }
      } else {
        cols <- groups;
      }
      cm <- counts;
      if(!all(rownames(cm) %in% names(cols))) { warning("cluster vector doesn't specify groups for all of the cells, dropping missing cells from comparison")}
      # determine a subset of cells that's in the cols and cols[cell]!=NA
      valid.cells <- rownames(cm) %in% names(cols)[!is.na(cols)];
      if(!all(valid.cells)) {
        # take a subset of the count matrix
        cm <- cm[valid.cells,]
      }
      # reorder cols
      cols <- as.factor(cols[match(rownames(cm),names(cols))]);

      cols <- as.factor(cols);
      if(verbose) {
        cat("running differential expression with ",length(levels(cols))," clusters ... ")
      }
      # use offsets based on the base model

      # run wilcoxon test comparing each group with the rest
      lower.lpv.limit <- -100;
      # calculate rank per-column (per-gene) average rank matrix
      xr <- sparse_matrix_column_ranks(cm);
      # calculate rank sums per group
      grs <- colSumByFac(xr,as.integer(cols))[-1,,drop=F]
      # calculate number of non-zero entries per group
      xr@x <- numeric(length(xr@x))+1
      gnzz <- colSumByFac(xr,as.integer(cols))[-1,,drop=F]
      #group.size <- as.numeric(tapply(cols,cols,length));
      group.size <- as.numeric(tapply(cols,cols,length))[1:nrow(gnzz)]; group.size[is.na(group.size)]<-0; # trailing empty levels are cut off by colSumByFac
      # add contribution of zero entries to the grs
      gnz <- (group.size-gnzz)
      # rank of a 0 entry for each gene
      zero.ranks <- (nrow(xr)-diff(xr@p)+1)/2 # number of total zero entries per gene
      ustat <- t((t(gnz)*zero.ranks)) + grs - group.size*(group.size+1)/2
      # standardize
      n1n2 <- group.size*(nrow(cm)-group.size);
      # usigma <- sqrt(n1n2*(nrow(cm)+1)/12) # without tie correction
      # correcting for 0 ties, of which there are plenty
      usigma <- sqrt(n1n2*(nrow(cm)+1)/12)
      usigma <- sqrt((nrow(cm) +1 - (gnz^3 - gnz)/(nrow(cm)*(nrow(cm)-1)))*n1n2/12)
      x <- t((ustat - n1n2/2)/usigma); # standardized U value- z score


      # correct for multiple hypothesis
      if(verbose) {
        cat("adjusting p-values ... ")
      }
      x <- matrix(qnorm(bh.adjust(pnorm(as.numeric(abs(x)), lower.tail = FALSE, log.p = TRUE), log = TRUE), lower.tail = FALSE, log.p = TRUE),ncol=ncol(x))*sign(x)
      rownames(x) <- colnames(cm); colnames(x) <- levels(cols)[1:ncol(x)];
      if(verbose) {
        cat("done.\n")
      }


      # add fold change information
      log.gene.av <- log2(Matrix::colMeans(cm));
      group.gene.av <- colSumByFac(cm,as.integer(cols))[-1,,drop=F] / (group.size+1);
      log2.fold.change <- log2(t(group.gene.av)) - log.gene.av;
      # fraction of cells expressing
      f.expressing <- t(gnzz / group.size);
      max.group <- max.col(log2.fold.change)

      if(upregulated.only) {
        ds <- lapply(1:ncol(x),function(i) {
          z <- x[,i];
          vi <- which(z>=z.threshold);
          r <- data.frame(Z=z[vi],M=log2.fold.change[vi,i],highest=max.group[vi]==i,fe=f.expressing[vi,i])
          rownames(r) <- rownames(x)[vi];
          r <- r[order(r$Z,decreasing=T),]
          r
        })
        #ds <- apply(x,2,function(z) {vi <- which(z>=z.threshold); r <- z[vi]; names(r) <- rownames(x)[vi]; sort(r,decreasing=T)})
      } else {
        ds <- lapply(1:ncol(x),function(i) {
          z <- x[,i];
          vi <- which(abs(z)>=z.threshold);
          r <- data.frame(Z=z[vi],M=log2.fold.change[vi,i],highest=max.group[vi]==i,fe=f.expressing[vi,i])
          rownames(r) <- rownames(x)[vi];
          r <- r[order(r$Z,decreasing=T),]
          r
        })
      }
      names(ds)<-colnames(x);

      if(is.null(groups)) {
        if(is.null(clusterType)) {
          diffgenes[[type]][[names(clusters[[type]])[1]]] <<- ds;
        } else {
          diffgenes[[type]][[clusterType]] <<- ds;
        }
      } else {
        diffgenes[[type]][[name]] <<- ds;
      }
      return(invisible(ds))
    },

    plotDiffGeneHeatmap=function(type='counts',clusterType=NULL, groups=NULL, n.genes=100, z.score=2, gradient.range.quantile=0.95, inner.clustering=FALSE, gradientPalette=NULL, v=0.8, s=1, box=TRUE, drawGroupNames=FALSE, ... ) {
      if(!is.null(clusterType)) {
        x <- diffgenes[[type]][[clusterType]];
        if(is.null(x)) { stop("differential genes for the specified cluster type haven't been calculated") }
      } else {
        x <- diffgenes[[type]][[1]];
        if(is.null(x)) { stop("no differential genes found for data type ",type) }
      }

      if(is.null(groups)) {
        # look up the clustering based on a specified type
        if(is.null(clusterType)) {
          # take the first one
          cols <- clusters[[type]][[1]]
        } else {
          cols <- clusters[[type]][[clusterType]]
          if(is.null(cols)) { stop("clustering ",clusterType," for type ", type," doesn't exist")}
        }
      } else {
        # use clusters information
        if(!all(rownames(counts) %in% names(groups))) { warning("provided cluster vector doesn't list groups for all of the cells")}
        cols <- as.factor(groups[match(rownames(counts),names(groups))]);
      }
      cols <- as.factor(cols);
      # select genes to show
      if(!is.null(z.score)) {
        x <- lapply(x,function(d) d[d$Z >= z.score & d$highest==T,])
        if(!is.null(n.genes)) {
          x <- lapply(x,function(d) {if(nrow(d)>0) { d[1:min(nrow(d),n.genes),]}})
        }
      } else {
        if(!is.null(n.genes)) {
          x <- lapply(x,function(d) {if(nrow(d)>0) { d[1:min(nrow(d),n.genes),]}})
        }
      }
      x <- lapply(x,rownames);
      # make expression matrix
      #browser()
      #x <- x[!unlist(lapply(x,is.null))]
      #cols <- cols[cols %in% names(x)]
      #cols <- droplevels(cols)
      em <- counts[,unlist(x)];
      # renormalize rows
      if(all(sign(em)>=0)) {
        if(is.null(gradientPalette)) {
          gradientPalette <- colorRampPalette(c('gray90','red'), space = "Lab")(1024)
        }
        em <- apply(em,1,function(x) {
          zlim <- as.numeric(quantile(x,p=c(1-gradient.range.quantile,gradient.range.quantile)))
          if(diff(zlim)==0) {
            zlim <- as.numeric(range(x))
          }
          x[x<zlim[1]] <- zlim[1]; x[x>zlim[2]] <- zlim[2];
          x <- (x-zlim[1])/(zlim[2]-zlim[1])
        })
      } else {
        if(is.null(gradientPalette)) {
          gradientPalette <- colorRampPalette(c("blue", "grey90", "red"), space = "Lab")(1024)
        }
        em <- apply(em,1,function(x) {
          zlim <- c(-1,1)*as.numeric(quantile(abs(x),p=gradient.range.quantile))
          if(diff(zlim)==0) {
            zlim <- c(-1,1)*as.numeric(max(abs(x)))
          }
          x[x<zlim[1]] <- zlim[1]; x[x>zlim[2]] <- zlim[2];
          x <- (x-zlim[1])/(zlim[2]-zlim[1])
        })
      }

      # cluster cell types by averages
      rowfac <- factor(rep(names(x),unlist(lapply(x,length))),levels=names(x))
      if(inner.clustering) {
        clclo <- hclust(as.dist(1-cor(do.call(cbind,tapply(1:nrow(em),rowfac,function(ii) Matrix::colMeans(em[ii,,drop=FALSE]))))),method='complete')$order
      } else {
        clclo <- 1:length(levels(rowfac))
      }

      if(inner.clustering) {
        # cluster genes within each cluster
        clgo <- tapply(1:nrow(em),rowfac,function(ii) {
          ii[hclust(as.dist(1-cor(t(em[ii,]))),method='complete')$order]
        })
      } else {
        clgo <- tapply(1:nrow(em),rowfac,I)
      }
      if(inner.clustering) {
        # cluster cells within each cluster
        clco <- tapply(1:ncol(em),cols,function(ii) {
          ii[hclust(as.dist(1-cor(em[,ii])),method='complete')$order]
        })
      } else {
        clco <- tapply(1:ncol(em),cols,I)
      }
      #clco <- clco[names(clgo)]
      # filter down to the clusters that are included
      #vic <- cols %in% clclo
      colors <- fac2col(cols,v=v,s=s,return.details=T)
      cellcols <- colors$colors[unlist(clco[clclo])]
      genecols <- rev(rep(colors$palette,unlist(lapply(clgo,length)[clclo])))
      bottomMargin <- ifelse(drawGroupNames,4,0.5);
      my.heatmap2(em[rev(unlist(clgo[clclo])),unlist(clco[clclo])],col=gradientPalette,Colv=NA,Rowv=NA,labRow=NA,labCol=NA,RowSideColors=genecols,ColSideColors=cellcols,margins=c(bottomMargin,0.5),ColSideColors.unit.vsize=0.05,RowSideColors.hsize=0.05,useRaster=T, box=box, ...)
      abline(v=cumsum(unlist(lapply(clco[clclo],length))),col=1,lty=3)
      abline(h=cumsum(rev(unlist(lapply(clgo[clclo],length)))),col=1,lty=3)
    },

    # recalculate library sizes using robust regression within clusters
    getRefinedLibSizes=function(clusterType=NULL, groups=NULL,type='counts') {
      if(is.null(groups)) {
        # look up the clustering based on a specified type
        if(is.null(clusterType)) {
          # take the first one
          groups <- clusters[[type]][[1]]
        } else {
          groups <- clusters[[type]][[clusterType]]
          if(is.null(groups)) { stop("clustering ",clusterType," for type ", type," doesn't exist")}
        }
      }
      if(is.null(groups)) { stop("clustering must be determined first, or passed as a groups parameter") }

      # calculated pooled profiles per cluster
      lvec <- colSumByFac(misc[['rawCounts']],as.integer(groups))[-1,,drop=F];
      lvec <- t(lvec/pmax(1,Matrix::rowSums(lvec)))*1e4

      # TODO: implement internal robust regression
      ## x <- misc[['rawCounts']]
      ## x <- x/as.numeric(depth);
      ## inplaceWinsorizeSparseCols(x,10);
      ## x <- x*as.numeric(depth);

      require(robustbase)
      x <- mclapply(1:length(levels(groups)),function(j) {
        ii <- names(groups)[which(groups==j)]
        av <- lvec[,j]
        avi <- which(av>0)
        av <- av[avi]
        cvm <- as.matrix(misc[['rawCounts']][ii,avi])
        x <- unlist(lapply(ii,function(i) {
          cv <- cvm[i,]
          #as.numeric(coef(glm(cv~av+0,family=poisson(link='identity'),start=sum(cv)/1e4)))
          as.numeric(coef(robustbase::glmrob(cv~av+0,family=poisson(link='identity'),start=sum(cv)/1e4)))
        }))
        names(x) <- ii;
        x
      },mc.cores=30)

      lib.sizes <- unlist(x)[rownames(misc[['rawCounts']])]
      lib.sizes <- lib.sizes/mean(lib.sizes)*mean(Matrix::rowSums(misc[['rawCounts']]))

      depth <<- lib.sizes;
      return(invisible(lib.sizes))
    },

    # plot heatmap for a given set of genes
    plotGeneHeatmap=function(genes, type='counts', clusterType=NULL, groups=NULL, z.score=2, gradient.range.quantile=0.95, cluster.genes=FALSE, inner.clustering=FALSE, gradientPalette=NULL, v=0.8, s=1, box=TRUE, drawGroupNames=FALSE, useRaster=TRUE, smooth.span=max(1,round(nrow(counts)/1024)), ... ) {
      if(is.null(groups)) {
        # look up the clustering based on a specified type
        if(is.null(clusterType)) {
          # take the first one
          cols <- clusters[[type]][[1]]
        } else {
          cols <- clusters[[type]][[clusterType]]
          if(is.null(cols)) { stop("clustering ",clusterType," for type ", type," doesn't exist")}
        }
      } else {
        # use clusters information
        if(!all(rownames(counts) %in% names(groups))) { warning("provided cluster vector doesn't list groups for all of the cells")}
        cols <- as.factor(groups[match(rownames(counts),names(groups))]);
      }
      cols <- as.factor(cols);
      # make expression matrix
      if(!all(genes %in% colnames(counts))) { warning(paste("the following specified genes were not found in the data: [",paste(genes[!genes %in% colnames(counts)],collapse=" "),"], omitting",sep="")) }
      x <- intersect(genes,colnames(counts));
      if(length(x)<1) { stop("too few genes") }
      em <- as.matrix(t(counts[,x]));

      # renormalize rows
      if(all(sign(em)>=0)) {
        if(is.null(gradientPalette)) {
          gradientPalette <- colorRampPalette(c('gray90','red'), space = "Lab")(1024)
        }
        em <- t(apply(em,1,function(x) {
          zlim <- as.numeric(quantile(x,p=c(1-gradient.range.quantile,gradient.range.quantile)))
          if(diff(zlim)==0) {
            zlim <- as.numeric(range(x))
          }
          x[x<zlim[1]] <- zlim[1]; x[x>zlim[2]] <- zlim[2];
          x <- (x-zlim[1])/(zlim[2]-zlim[1])
        }))
      } else {
        if(is.null(gradientPalette)) {
          gradientPalette <- colorRampPalette(c("blue", "grey90", "red"), space = "Lab")(1024)
        }
        em <- t(apply(em,1,function(x) {
          zlim <- c(-1,1)*as.numeric(quantile(abs(x),p=gradient.range.quantile))
          if(diff(zlim)==0) {
            zlim <- c(-1,1)*as.numeric(max(abs(x)))
          }
          x[x<zlim[1]] <- zlim[1]; x[x>zlim[2]] <- zlim[2];
          x <- (x-zlim[1])/(zlim[2]-zlim[1])
        }))
      }

      # cluster cell types by averages
      clclo <- 1:length(levels(cols))

      if(cluster.genes) {
        # cluster genes within each cluster
        clgo <- hclust(as.dist(1-cor(t(em))),method='complete')$order
      } else {
        clgo <- 1:nrow(em)
      }

      if(inner.clustering) {
        # cluster cells within each cluster
        clco <- tapply(1:ncol(em),cols,function(ii) {
          ii[hclust(as.dist(1-cor(em[,ii])),method='single')$order]
          # TODO: implement smoothing span support
        })
      } else {
        clco <- tapply(1:ncol(em),cols,I)
      }

      cellcols <- fac2col(cols,v=v,s=s)[unlist(clco[clclo])]
      #genecols <- rev(rep(fac2col(cols,v=v,s=s,return.level.colors=T),unlist(lapply(clgo,length)[clclo])))
      bottomMargin <- 0.5;
      # reorder and potentially smooth em
      em <- em[rev(clgo),unlist(clco[clclo])];

      my.heatmap2(em,col=gradientPalette,Colv=NA,Rowv=NA,labCol=NA,ColSideColors=cellcols,margins=c(bottomMargin,5),ColSideColors.unit.vsize=0.05,RowSideColors.hsize=0.05,useRaster=useRaster, box=box, ...)
      bp <- cumsum(unlist(lapply(clco[clclo],length))); # cluster border positions
      abline(v=bp,col=1,lty=3)
      #abline(h=cumsum(rev(unlist(lapply(clgo[clclo],length)))),col=1,lty=3)
      if(drawGroupNames) {
        clpos <- (c(0,bp[-length(bp)])+bp)/2;
        labpos <- rev(seq(0,length(bp)+1)/(length(bp)+1)*nrow(em)); labpos <- labpos[-1]; labpos <- labpos[-length(labpos)]
        text(x=clpos,y=labpos,labels = levels(col),cex=1)
        # par(xpd=TRUE)
        # clpos <- (c(0,bp[-length(bp)])+bp)/2;
        # labpos <- seq(0,length(bp)+1)/(length(bp)+1)*max(bp); labpos <- labpos[-1]; labpos <- labpos[-length(labpos)]
        # text(x=labpos,y=-2,labels = levels(col))
        # segments(labpos,-1,clpos,0.5,lwd=0.5)
        # par(xpd=FALSE)
      }
    },

    # show embedding
    plotEmbedding=function(type='counts', embeddingType=NULL, clusterType=NULL, groups=NULL, colors=NULL, do.par=T, cex=0.6, alpha=0.4, gradientPalette=NULL, zlim=NULL, s=1, v=0.8, min.group.size=1, show.legend=FALSE, mark.clusters=FALSE, mark.cluster.cex=2, shuffle.colors=F, legend.x='topright', gradient.range.quantile=0.95, quiet=F, unclassified.cell.color='gray70', group.level.colors=NULL, ...) {
      if(is.null(embeddings[[type]])) { stop("first, generate embeddings for type ",type)}
      if(is.null(embeddingType)) {
        # take the first one
        emb <- embeddings[[type]][[1]]
      } else {
        emb <- embeddings[[type]][[embeddingType]]
      }
      factor.mapping=FALSE;
      if(is.null(colors) && is.null(groups)) {
        # look up the clustering based on a specified type
        if(is.null(clusterType)) {
          # take the first one
          groups <- clusters[[type]][[1]]
        } else {
          groups <- clusters[[type]][[clusterType]]
          if(is.null(groups)) { stop("clustering ",clusterType," for type ", type," doesn't exist")}
        }

        groups <- as.factor(groups[rownames(emb)]);
        if(min.group.size>1) { groups[groups %in% levels(groups)[unlist(tapply(groups,groups,length))<min.group.size]] <- NA; groups <- as.factor(groups); }
        factor.colors <- fac2col(groups,s=s,v=v,shuffle=shuffle.colors,min.group.size=min.group.size,level.colors=group.level.colors,return.details=T)
        cols <- factor.colors$colors[rownames(emb)]
        factor.mapping=TRUE;
      } else {
        if(!is.null(colors)) {
          # use clusters information
          if(!all(rownames(emb) %in% names(colors))) { warning("provided cluster vector doesn't list colors for all of the cells; unmatched cells will be shown in gray. ")}
          if(all(areColors(colors))) {
            if(!quiet) cat("using supplied colors as is\n")
            cols <- colors[match(rownames(emb),names(colors))]; cols[is.na(cols)] <- unclassified.cell.color;
          } else {
            if(is.numeric(colors)) { # treat as a gradient
              if(!quiet) cat("treating colors as a gradient")
              if(is.null(gradientPalette)) { # set up default gradients
                if(all(sign(colors)>=0)) {
                  gradientPalette <- colorRampPalette(c('gray80','red'), space = "Lab")(1024)
                } else {
                  gradientPalette <- colorRampPalette(c("blue", "grey70", "red"), space = "Lab")(1024)
                }
              }
              if(is.null(zlim)) { # set up value limits
                if(all(sign(colors)>=0)) {
                  zlim <- as.numeric(quantile(colors,p=c(1-gradient.range.quantile,gradient.range.quantile)))
                  if(diff(zlim)==0) {
                    zlim <- as.numeric(range(colors))
                  }
                } else {
                  zlim <- c(-1,1)*as.numeric(quantile(abs(colors),p=gradient.range.quantile))
                  if(diff(zlim)==0) {
                    zlim <- c(-1,1)*as.numeric(max(abs(colors)))
                  }
                }
              }
              # restrict the values
              colors[colors<zlim[1]] <- zlim[1]; colors[colors>zlim[2]] <- zlim[2];

              if(!quiet) cat(' with zlim:',zlim,'\n')
              colors <- (colors-zlim[1])/(zlim[2]-zlim[1])
              cols <- gradientPalette[colors[match(rownames(emb),names(colors))]*(length(gradientPalette)-1)+1]
            } else {
              stop("colors argument must be a cell-named vector of either character colors or numeric values to be mapped to a gradient")
            }
          }
        } else {
          if(!is.null(groups)) {
            if(min.group.size>1) { groups[groups %in% levels(groups)[unlist(tapply(groups,groups,length))<min.group.size]] <- NA; groups <- droplevels(groups); }
            groups <- as.factor(groups)[rownames(emb)]
            if(!quiet) cat("using provided groups as a factor\n")
            factor.mapping=TRUE;
            # set up a rainbow color on the factor
            factor.colors <- fac2col(groups,s=s,v=v,shuffle=shuffle.colors,min.group.size=min.group.size,unclassified.cell.color=unclassified.cell.color,level.colors=group.level.colors,return.details=T)
            cols <- factor.colors$colors;
          }
        }
        names(cols) <- rownames(emb)
      }

      if(do.par) {
        par(mar = c(0.5,0.5,2.0,0.5), mgp = c(2,0.65,0), cex = 1.0);
      }
      plot(emb,col=adjustcolor(cols,alpha=alpha),cex=cex,pch=19,axes=F, panel.first=grid(), ...); box();
      if(mark.clusters) {
        if(!is.null(groups)) {
          cent.pos <- do.call(rbind,tapply(1:nrow(emb),groups,function(ii) apply(emb[ii,,drop=F],2,median)))
          #rownames(cent.pos) <- levels(groups);
          cent.pos <- na.omit(cent.pos);
          text(cent.pos[,1],cent.pos[,2],labels=rownames(cent.pos),cex=mark.cluster.cex)
        }
      }
      if(show.legend) {
        if(factor.mapping) {
          legend(x=legend.x,pch=rep(19,length(levels(groups))),bty='n',col=factor.colors$palette,legend=names(factor.colors$palette))
        }
      }

    },
    # get overdispersed genes
    getOdGenes=function(n.odgenes=NULL,alpha=5e-2,use.unadjusted.pvals=FALSE) {
      if(is.null(misc[['varinfo']])) { stop("please run adjustVariance first")}
      if(is.null(n.odgenes)) { #return according to alpha
        if(use.unadjusted.pvals) {
          rownames(misc[['varinfo']])[misc[['varinfo']]$lp <= log(alpha)]
        } else {
          rownames(misc[['varinfo']])[misc[['varinfo']]$lpa <= log(alpha)]
        }
      } else { # return top n.odgenes sites
        rownames(misc[['varinfo']])[(order(misc[['varinfo']]$lp,decreasing=F)[1:min(ncol(counts),n.odgenes)])]
      }
    },

    # run PCA analysis on the overdispersed genes
    calculatePcaReduction=function(nPcs=20, type='counts', name='PCA', use.odgenes=FALSE, n.odgenes=2e3, odgenes=NULL, scale=F,center=T, cells=NULL,fastpath=TRUE,maxit=100) {

      if(type=='counts') {
        x <- counts;
      } else {
        if(!type %in% names(reductions)) { stop("reduction ",type,' not found')}
        x <- reductions[[type]]
      }
      if((use.odgenes || !is.null(n.odgenes)) && is.null(odgenes)) {
        if(is.null(misc[['odgenes']] )) { stop("please run adjustVariance() first")}
        odgenes <- misc[['odgenes']];
        if(!is.null(n.odgenes)) {
          if(n.odgenes>length(odgenes)) {
            #warning("number of specified odgenes is higher than the number of the statistically significant sites, will take top ",n.odgenes,' sites')
            odgenes <- rownames(misc[['varinfo']])[(order(misc[['varinfo']]$lp,decreasing=F)[1:min(ncol(counts),n.odgenes)])]
          } else {
            odgenes <- odgenes[1:n.odgenes]
          }
        }
      }
      if(!is.null(odgenes)) { x <- x[,odgenes] }

      # apply scaling if using raw counts
      if(type=='counts') {
        #x <- t(t(x)*misc[['varinfo']][colnames(x),'gsf'])
        x@x <- x@x*rep(misc[['varinfo']][colnames(x),'gsf'],diff(x@p))
      }

      require(irlba)
      if(!is.null(cells)) {
        # cell subset is just for PC determination
        cm <- Matrix::colMeans(x[cells,])
        pcs <- irlba(x[cells,], nv=nPcs, nu=0, center=cm, right_only=FALSE,fastpath=fastpath,maxit=maxit,reorth=T)
      } else {
        if(center) {
          cm <- Matrix::colMeans(x)
          pcs <- irlba(x, nv=nPcs, nu=0, center=cm, right_only=FALSE,fastpath=fastpath,maxit=maxit,reorth=T)
        } else {
          pcs <- irlba(x, nv=nPcs, nu=0, right_only=FALSE,fastpath=fastpath,maxit=maxit,reorth=T)
        }
      }
      rownames(pcs$v) <- colnames(x);



      # adjust for centering!
      if(center) {
        pcs$center <- cm;
        pcas <- as.matrix(t(t(x %*% pcs$v) - t(cm %*% pcs$v)))
      } else {
        pcas <- as.matrix(x %*% pcs$v);
      }
      misc$PCA <<- pcs;
      #pcas <- scde::winsorize.matrix(pcas,0.05)
      # # control for sequencing depth
      # if(is.null(batch)) {
      #   mx <- model.matrix(x ~ d,data=data.frame(x=1,d=depth))
      # } else {
      #   mx <- model.matrix(x ~ d*b,data=data.frame(x=1,d=depth,b=batch))
      # }
      # # TODO: how to get rid of residual depth effects in the PCA-based clustering?
      # #pcas <- t(t(colLm(pcas,mx,returnResid=TRUE))+Matrix::colMeans(pcas))
      # pcas <- colLm(pcas,mx,returnResid=TRUE)
      rownames(pcas) <- rownames(x)
      colnames(pcas) <- paste('PC',seq(ncol(pcas)),sep='')
      #pcas <- pcas[,-1]
      #pcas <- scde::winsorize.matrix(pcas,0.1)

      reductions[[name]] <<- pcas;
      ## nIcs <- nPcs;
      ## a <- ica.R.def(t(pcas),nIcs,tol=1e-3,fun='logcosh',maxit=200,verbose=T,alpha=1,w.init=matrix(rnorm(nIcs*nPcs),nIcs,nPcs))
      ## reductions[['ICA']] <<- as.matrix( x %*% pcs$v %*% a);
      ## colnames(reductions[['ICA']]) <<- paste('IC',seq(ncol(reductions[['ICA']])),sep='');

      return(invisible(pcas))
    },


    # test pathway overdispersion
    # this is a compressed version of the PAGODA1 approach
    # env - pathway to gene environment
    testPathwayOverdispersion=function(setenv, type='counts', max.pathway.size=1e3, min.pathway.size=10, n.randomizations=10, verbose=FALSE, score.alpha=0.05, plot=FALSE, cells=NULL,adjusted.pvalues=TRUE,z.score = qnorm(0.05/2, lower.tail = FALSE), use.oe.scale = FALSE, return.table=FALSE,name='pathwayPCA',correlation.distance.threshold=0.2,top.aspects=Inf,recalculate.pca=FALSE,save.pca=TRUE) {
      nPcs <- 1;

      if(type=='counts') {
        x <- counts;
        # apply scaling if using raw counts
        x@x <- x@x*rep(misc[['varinfo']][colnames(x),'gsf'],diff(x@p))
      } else {
        if(!type %in% names(reductions)) { stop("reduction ",type,' not found')}
        x <- reductions[[type]]
      }
      if(!is.null(cells)) {
        x <- x[cells,]
      }

      proper.gene.names <- colnames(x);

      if(is.null(misc[['pwpca']]) || recalculate.pca) {
        if(verbose) {
          message("determining valid pathways")
        }

        # determine valid pathways
        gsl <- ls(envir = setenv)
        gsl.ng <- unlist(mclapply(sn(gsl), function(go) sum(unique(get(go, envir = setenv)) %in% proper.gene.names),mc.cores=n.cores,mc.preschedule=T))
        gsl <- gsl[gsl.ng >= min.pathway.size & gsl.ng<= max.pathway.size]
        names(gsl) <- gsl

        if(verbose) {
          message("processing ", length(gsl), " valid pathways")
        }

        require(irlba)
        cm <- Matrix::colMeans(x)

        pwpca <- papply(gsl, function(sn) {
          lab <- proper.gene.names %in% get(sn, envir = setenv)
          if(sum(lab)<1) { return(NULL) }
          pcs <- irlba(x[,lab], nv=nPcs, nu=0, center=cm[lab], right_only=TRUE,fastpath=T,reorth=T)
          pcs$d <- pcs$d/sqrt(nrow(x))
          pcs$rotation <- pcs$v;
          pcs$v <- NULL;

          # get standard deviations for the random samples
          ngenes <- sum(lab)
          z <- do.call(rbind,lapply(seq_len(n.randomizations), function(i) {
            si <- sample(ncol(x), ngenes)
            pcs <- irlba(x[,si], nv=nPcs, nu=0, center=cm[si], right_only=FALSE,fastpath=T,reorth=T)$d
          }))
          z <- z/sqrt(nrow(x));



          # local normalization of each component relative to sampled PC1 sd
          avar <- pmax(0, (pcs$d^2-mean(z[, 1]^2))/sd(z[, 1]^2))

          if(avar>0.5) {
            # flip orientations to roughly correspond with the means
            pcs$scores <- as.matrix(t(x[,lab] %*% pcs$rotation) - as.numeric((cm[lab] %*% pcs$rotation)))
            cs <- unlist(lapply(seq_len(nrow(pcs$scores)), function(i) sign(cor(pcs$scores[i,], colMeans(t(x[, lab, drop = FALSE])*abs(pcs$rotation[, i]))))))
            pcs$scores <- pcs$scores*cs
            pcs$rotation <- pcs$rotation*cs
            rownames(pcs$rotation) <- colnames(x)[lab];
          } # don't bother otherwise - it's not significant
          return(list(xp=pcs,z=z,n=ngenes))
        }, n.cores = n.cores,mc.preschedule=T)
        if(save.pca) {
          misc[['pwpca']] <<- pwpca;
        }
      } else {
        if(verbose) {
          message("reusing previous overdispersion calculations")
          pwpca <- misc[['pwpca']];
        }
      }

      if(verbose) {
        message("scoring pathway od signifcance")
      }

      # score overdispersion
      true.n.cells <- nrow(x)

      pagoda.effective.cells <- function(pwpca, start = NULL) {
        n.genes <- unlist(lapply(pwpca, function(x) rep(x$n, nrow(x$z))))
        var <- unlist(lapply(pwpca, function(x) x$z[, 1]))
        if(is.null(start)) { start <- true.n.cells*2 } # start with a high value
        of <- function(p, v, sp) {
          sn <- p[1]
          vfit <- (sn+sp)^2/(sn*sn+1/2) -1.2065335745820*(sn+sp)*((1/sn + 1/sp)^(1/3))/(sn*sn+1/2)
          residuals <- (v-vfit)^2
          return(sum(residuals))
        }
        x <- nlminb(objective = of, start = c(start), v = var, sp = sqrt(n.genes-1/2), lower = c(1), upper = c(true.n.cells))
        return((x$par)^2+1/2)
      }
      n.cells <- pagoda.effective.cells(pwpca)

      vdf <- data.frame(do.call(rbind, lapply(seq_along(pwpca), function(i) {
        vars <- as.numeric((pwpca[[i]]$xp$d))
        cbind(i = i, var = vars, n = pwpca[[i]]$n, npc = seq(1:ncol(pwpca[[i]]$xp$rotation)))
      })))

      # fix p-to-q mistake in qWishartSpike
      qWishartSpikeFixed <- function (q, spike, ndf = NA, pdim = NA, var = 1, beta = 1, lower.tail = TRUE, log.p = FALSE)  {
        params <- RMTstat::WishartSpikePar(spike, ndf, pdim, var, beta)
        qnorm(q, mean = params$centering, sd = params$scaling, lower.tail, log.p)
      }

      # add right tail approximation to ptw, which gives up quite early
      pWishartMaxFixed <- function (q, ndf, pdim, var = 1, beta = 1, lower.tail = TRUE) {
        params <- RMTstat::WishartMaxPar(ndf, pdim, var, beta)
        q.tw <- (q - params$centering)/(params$scaling)
        p <- RMTstat::ptw(q.tw, beta, lower.tail, log.p = TRUE)
        p[p == -Inf] <- pgamma((2/3)*q.tw[p == -Inf]^(3/2), 2/3, lower.tail = FALSE, log.p = TRUE) + lgamma(2/3) + log((2/3)^(1/3))
        p
      }

      vshift <- 0
      ev <- 0

      vdf$var <- vdf$var-(vshift-ev)*vdf$n
      basevar <- 1
      vdf$exp <- RMTstat::qWishartMax(0.5, n.cells, vdf$n, var = basevar, lower.tail = FALSE)
      #vdf$z <- qnorm(pWishartMax(vdf$var, n.cells, vdf$n, log.p = TRUE, lower.tail = FALSE, var = basevar), lower.tail = FALSE, log.p = TRUE)
      vdf$z <- qnorm(pWishartMaxFixed(vdf$var, n.cells, vdf$n, lower.tail = FALSE, var = basevar), lower.tail = FALSE, log.p = TRUE)
      vdf$cz <- qnorm(bh.adjust(pnorm(as.numeric(vdf$z), lower.tail = FALSE, log.p = TRUE), log = TRUE), lower.tail = FALSE, log.p = TRUE)
      vdf$ub <- RMTstat::qWishartMax(score.alpha/2, n.cells, vdf$n, var = basevar, lower.tail = FALSE)
      vdf$ub.stringent <- RMTstat::qWishartMax(score.alpha/nrow(vdf)/2, n.cells, vdf$n, var = basevar, lower.tail = FALSE)

      if(plot) {
        par(mfrow = c(1, 1), mar = c(3.5, 3.5, 1.0, 1.0), mgp = c(2, 0.65, 0))
        un <- sort(unique(vdf$n))
        on <- order(vdf$n, decreasing = FALSE)
        pccol <- colorRampPalette(c("black", "grey70"), space = "Lab")(max(vdf$npc))
        plot(vdf$n, vdf$var/vdf$n, xlab = "gene set size", ylab = "PC1 var/n", ylim = c(0, max(vdf$var/vdf$n)), col = adjustcolor(pccol[vdf$npc],alpha=0.1),pch=19)
        lines(vdf$n[on], (vdf$exp/vdf$n)[on], col = 2, lty = 1)
        lines(vdf$n[on], (vdf$ub.stringent/vdf$n)[on], col = 2, lty = 2)
      }

      rs <- (vshift-ev)*vdf$n
      vdf$oe <- (vdf$var+rs)/(vdf$exp+rs)
      vdf$oec <- (vdf$var+rs)/(vdf$ub+rs)

      df <- data.frame(name = names(pwpca)[vdf$i], npc = vdf$npc, n = vdf$n, score = vdf$oe, z = vdf$z, adj.z = vdf$cz, stringsAsFactors = FALSE)
      if(adjusted.pvalues) {
        vdf$valid <- vdf$cz  >=  z.score
      } else {
        vdf$valid <- vdf$z  >=  z.score
      }

      if(!any(vdf$valid)) { stop("no significantly overdispersed pathways found at z.score threshold of ",z.score) };

      # apply additional filtering based on >0.5 sd above the local random estimate
      vdf$valid <- vdf$valid & unlist(lapply(pwpca,function(x) !is.null(x$xp$scores)))
      vdf$name <- names(pwpca)[vdf$i];

      if(return.table) {
        df <- df[vdf$valid, ]
        df <- df[order(df$score, decreasing = TRUE), ]
        return(df)
      }
      if(verbose) {
        message("compiling pathway reduction")
      }
      # calculate pathway reduction matrix

      # return scaled patterns
      xmv <- do.call(rbind, lapply(pwpca[vdf$valid], function(x) {
        xm <- x$xp$scores
      }))

      if(use.oe.scale) {
        xmv <- (xmv -rowMeans(xmv))* (as.numeric(vdf$oe[vdf$valid])/sqrt(apply(xmv, 1, var)))
        vdf$sd <- as.numeric(vdf$oe)
      } else {
        # chi-squared
        xmv <- (xmv-rowMeans(xmv)) * sqrt((qchisq(pnorm(vdf$z[vdf$valid], lower.tail = FALSE, log.p = TRUE), n.cells, lower.tail = FALSE, log.p = TRUE)/n.cells)/apply(xmv, 1, var))
        vdf$sd <- sqrt((qchisq(pnorm(vdf$z, lower.tail = FALSE, log.p = TRUE), n.cells, lower.tail = FALSE, log.p = TRUE)/n.cells))

      }
      rownames(xmv) <- paste("#PC", vdf$npc[vdf$valid], "# ", names(pwpca)[vdf$i[vdf$valid]], sep = "")
      rownames(vdf) <- paste("#PC", vdf$npc, "# ", vdf$name, sep = "")
      misc[['pathwayODInfo']] <<- vdf

      # collapse gene loading
      if(verbose) {
        message("clustering aspects based on gene loading")
      }
      tam2 <- pagoda.reduce.loading.redundancy(list(xv=xmv,xvw=matrix(1,ncol=ncol(xmv),nrow=nrow(xmv))),pwpca,NULL,plot=F,n.cores=n.cores)
      if(verbose) {
        message("clustering aspects based on pattern similarity")
      }
      tam3 <- pagoda.reduce.redundancy(tam2,distance.threshold=correlation.distance.threshold,top=top.aspects)

      tam2$xvw <- tam3$xvw <- NULL; # to save space
      misc[['pathwayOD']] <<- tam3;
      reductions[[name]] <<- tam3$xv;
      return(invisible(tam3))
    },

    getEmbedding=function(type='counts', embeddingType='largeVis', name=NULL, M=5, gamma=1, perplexity=100, sgd_batches=2e6, diffusion.steps=0, diffusion.power=0.5, ... ) {
      if(type=='counts') {
        x <- counts;
      } else {
        if(!type %in% names(reductions)) { stop("reduction ",type,' not found')}
        x <- reductions[[type]]
      }
      if(is.null(name)) { name <- embeddingType }
      if(embeddingType=='largeVis') {
        xn <- misc[['edgeMat']][[type]];
        if(is.null(xn)) { stop(paste('KNN graph for type ',type,' not found. Please run makeKnnGraph with type=',type,sep='')) }
        edgeMat <- sparseMatrix(i=xn$s+1,j=xn$e+1,x=xn$rd,dims=c(nrow(x),nrow(x)))
        edgeMat <- edgeMat + t(edgeMat); # symmetrize
        #edgeMat <- sparseMatrix(i=c(xn$s,xn$e)+1,j=c(xn$e,xn$s)+1,x=c(xn$rd,xn$rd),dims=c(nrow(x),nrow(x)))
        # if(diffusion.steps>0) {
        #   Dinv <- Diagonal(nrow(edgeMat),1/colSums(edgeMat))
        #   Im <- Diagonal(nrow(edgeMat))
        #   W <- (Diagonal(nrow(edgeMat)) + edgeMat %*% Dinv)/2
        #   for(i in 1:diffusion.steps) {
        #     edgeMat <- edgeMat %*% W
        #   }
        # }
        require(largeVis)
        #if(!is.null(seed)) { set.seed(seed) }
        wij <- buildWijMatrix(edgeMat,perplexity=perplexity,threads=n.cores)

        if(diffusion.steps>0) {
          Dinv <- Diagonal(nrow(wij),1/colSums(wij))
          W <- Dinv %*% wij ;
          W <- (1-diffusion.power)*Diagonal(nrow(wij)) + diffusion.power*W
          #W <- (Diagonal(nrow(wij)) + W)/2
          #W <- (Diagonal(nrow(wij)) + sign(W)*(abs(W)^(diffusion.power)))/2

          #W <- sign(W)*(abs(W)^diffusion.power)
          #W <- (Diagonal(nrow(wij)) + W)/2
          for(i in 1:diffusion.steps) {
            wij <- wij %*% W
          }
          #browser()
          wij <- buildWijMatrix(wij,perplexity=perplexity,threads=n.cores)
        }
        coords <- projectKNNs(wij = wij, M = M, verbose = TRUE,sgd_batches = sgd_batches,gamma=gamma, seed=1, ...)
        colnames(coords) <- rownames(x);
        emb <- embeddings[[type]][[name]] <<- t(coords);
      } else if(embeddingType=='tSNE') {
        require(Rtsne);
        cat("calculating distance ... ")
        #d <- dist(x);
        d <- as.dist(1-cor(t(x), method = 'pearson'))
        #d <- as.dist(1-cor(x))
        cat("done\n")
        emb <- Rtsne(d,is_distance=T, perplexity=perplexity, ...)$Y;
        rownames(emb) <- labels(d)
        embeddings[[type]][[name]] <<- emb;
      } else if(embeddingType=='FR') {
        g <- graphs[[type]];
        if(is.null(g)){ stop(paste("generate KNN graph first (type=",type,")",sep=''))}
        emb <- layout.fruchterman.reingold(g, weights=E(g)$weight)
        rownames(emb) <- colnames(mat); colnames(emb) <- c("D1","D2")
        embeddings[[type]][[name]] <<- emb;
      } else {
        stop('unknown embeddingType ',embeddingType,' specified');
      }

      return(invisible(emb));
     }
  )
);

# a utility function to translate factor into colors
fac2col <- function(x,s=1,v=1,shuffle=FALSE,min.group.size=1,return.details=F,unclassified.cell.color='gray50',level.colors=NULL) {
  x <- as.factor(x);
  if(min.group.size>1) {
    x <- factor(x,exclude=levels(x)[unlist(tapply(rep(1,length(x)),x,length))<min.group.size])
    x <- droplevels(x)
  }
  if(is.null(level.colors)) {
    col <- rainbow(length(levels(x)),s=s,v=v);
  } else {
    col <- level.colors[1:length(levels(x))];
  }
  names(col) <- levels(x);

  if(shuffle) col <- sample(col);

  y <- col[as.integer(x)]; names(y) <- names(x);
  y[is.na(y)] <- unclassified.cell.color;
  if(return.details) {
    return(list(colors=y,palette=col))
  } else {
    return(y);
  }
}

val2col <- function(x,gradientPalette=NULL,zlim=NULL,gradient.range.quantile=0.95) {
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

  gradientPalette[x*(length(gradientPalette)-1)+1]
}


# note transpose is meant to speed up calculations when neither scaling nor centering is required
fast.pca <- function(m,nPcs=2,tol=1e-10,scale=F,center=F,transpose=F) {
  require(irlba)
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

# quick utility to check if given character vector is colors
# thanks, Josh O'Brien: http://stackoverflow.com/questions/13289009/check-if-character-string-is-a-valid-color-representation
areColors <- function(x) {
  is.character(x) & sapply(x, function(X) {tryCatch(is.matrix(col2rgb(X)), error = function(e) FALSE)})
}

papply <- function(...,n.cores=detectCores(), mc.preschedule=FALSE) {
  if(n.cores>1) {
    # bplapply implementation
    if(is.element("parallel", installed.packages()[,1])) {
      mclapply(...,mc.cores=n.cores,mc.preschedule=mc.preschedule)
    } else {
      # last resort
      bplapply(... , BPPARAM = MulticoreParam(workers = n.cores))
    }
  } else { # fall back on lapply
    lapply(...);
  }
}
jw.disR <- function(x,y) { x <- x+1/length(x)/1e3; y <- y+1/length(y)/1e3; a <- x*log(x)  + y*log(y) - (x+y)*log((x+y)/2); sqrt(sum(a)/2)}


# translate multilevel segmentation into a dendrogram, with the lowest level of the dendrogram listing the cells
multi2dend <- function(cl,counts,deep=F) {
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
  lvec.dist <- jsDist(t(lvec/pmax(1,Matrix::rowSums(lvec))));
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
