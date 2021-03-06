library(data.table)

.messagef <- function (...)  { message(sprintf(...)) }
.warningf <- function (...)  { warning(sprintf(...)) }

.replaceNA <- function(x, y) { ifelse(is.na(x), y, x) }

.pairwiseCompare <- function (FUN, list1, list2 = list1, ...)
{
    additionalArguments <- list(...)
    f1 <- function(...) {
        mapply(FUN = function(x, y) {
            do.call(FUN, c(list(list1[[x]], list2[[y]]), additionalArguments))
        }, ...)
    }
    z <- outer(seq_along(list1), seq_along(list2), FUN = f1)
    rownames(z) <- names(list1)
    colnames(z) <- names(list2)
    z
}
.intersectionSize <- function(...) { length(intersect(...))}

findColumn <- function(de, names) {
     candidates <-  na.omit(match(tolower(names),
                                  tolower(colnames(de))))
     if (length(candidates) == 0) {
         return(NA)
     }
     return(colnames(de)[candidates[1]])
}

findIdColumn <- function(de, idsList,
                         sample.size=1000,
                         match.threshold=0.6,
                         remove.ensembl.revisions=TRUE) {
    # first looking for column with base IDs
    de.sample <- if (nrow(de) < sample.size) {
        copy(de)
    } else {
        de[sample(seq_len(nrow(de)), sample.size), ]
    }
    columnSamples <- lapply(de.sample, as.character)


    if (remove.ensembl.revisions) {
        columnSamples <- lapply(columnSamples, gsub,
                                pattern="(ENS\\w*\\d*)\\.\\d*",
                                replacement="\\1")
    }

    ss <- sapply(columnSamples,
                 .intersectionSize, idsList[[1]])

    if (max(ss) / nrow(de.sample) >= match.threshold) {
        # we found a good column with base IDs
        return(list(column=colnames(de)[which.max(ss)],
                    type=names(idsList)[1],
                    match.ratio=max(ss) / nrow(de.sample)))
    }

    z <- .pairwiseCompare(.intersectionSize,
                         columnSamples,
                         idsList)

    bestMatch <- which(z == max(z), arr.ind = TRUE)[1,]
    return(list(column=colnames(de)[bestMatch["row"]],
                type=names(idsList)[bestMatch["col"]],
                match.ratio=max(z) / nrow(de.sample)))
}

idsListFromAnnotation <- function(org.anno) {
    res <- c(list(org.anno$genes$gene),
                  lapply(names(org.anno$mapFrom),
                         function(n) org.anno$mapFrom[[n]][[n]])
    )
    names(res) <- c(org.anno$baseId, names(org.anno$mapFrom))
    res
}

#' Finds columns in gene differential expression table
#' required for gatom analysis
#' @param gene.de.raw A table with differential expression results, an object
#'        convertable to data.frame.
#' @param org.annos List of Organsim-specific annotation obtained from
#'                       makeOrgAnnotation function
getGeneDEMeta <- function(gene.de.raw, org.annos,
                          organism=NULL,
                          idColumn=NULL,
                          idType=NULL,
                          baseMeanColumn=NULL,
                          statColumn=NULL
                          ) {

    if (is.null(idColumn) != is.null(idType)) {
        stop("Either both or none of idColumn and idType can be specified")
    }
    
    if (is.null(idColumn)) {
        orgMatches <- rbindlist(lapply(names(org.annos), function(org) {
            idsList <- idsListFromAnnotation(org.annos[[org]])
            idColumnInfo <- findIdColumn(gene.de.raw, idsList)    
            idColumnInfo$organism <- org
            idColumnInfo
        }))
        setkey(orgMatches, "organism")
        
        organism <- orgMatches[match.ratio >= 0.6, organism[which.max(match.ratio)]]
        
        if (is.null(organism)) {
            organism <- NA
            idColumn <- NA
            idType <- NA
        } else {
            idColumn <- orgMatches[organism, column]
            idType <- orgMatches[organism, type]
        }
    
    }

    if (is.null(baseMeanColumn)) {
        baseMeanColumn <- findColumn(gene.de.raw,
                                     c("baseMean", "aveexpr"))
    }

    if (is.null(statColumn)) {
        statColumn <- findColumn(gene.de.raw,
                                 c("stat", "t", "log2FC", "log2foldchange", "logfc"))
    }

    list(organism=organism,
         idType=idType,
         columns=list(
             ID=idColumn,
             baseMean=baseMeanColumn,
             stat=statColumn
             ))
}


#' @export
makeOrgAnnotation <- function(org.db,
                                   idColumns=
                                       c("Entrez"="ENTREZID",
                                         "RefSeq"="REFSEQ",
                                         "Ensembl"="ENSEMBL",
                                         "Symbol"="SYMBOL"),
                                   nameColumn="SYMBOL") {

    stopifnot(requireNamespace("AnnotationDbi"))
    baseColumn <- idColumns[1]

    org.anno <- list()
    org.anno$genes <- data.table(gene=keys(org.db, keytype = baseColumn))
    setkey(org.anno$genes, gene)
    org.anno$genes[, symbol := AnnotationDbi::mapIds(org.db, keys=gene,
                                            keytype = baseColumn,
                                            column = nameColumn)]
    org.anno$baseId <- names(baseColumn)

    org.anno$mapFrom <- list()
    for (i in tail(seq_along(idColumns), -1)) {
        otherColumn <- idColumns[i]
        n <- names(otherColumn)
        org.anno$mapFrom[[n]] <- data.table(AnnotationDbi::select(org.db,
                                                         keys=org.anno$genes$gene,
                                                         columns = otherColumn))
        org.anno$mapFrom[[n]] <- na.omit(org.anno$mapFrom[[n]])
        setnames(org.anno$mapFrom[[n]],
                 c(baseColumn, otherColumn),
                 c("gene", names(otherColumn)))
        setkeyv(org.anno$mapFrom[[n]], n)
    }

    org.anno
}

#' Makes data.table with differential expression results containing
#' all columns required for gatom and in the expected format
#' based on metadata object
#' @param de.raw Table with defferential expression results, an object
#'        convertable to data.frame
#' @param de.met Object with differential expression table metadata
#'        acquired with getGeneDEMeta or getMetDEMeta functions
#' @return data.table object with converted differential expressiond table
#' @export
#' @importFrom methods is
prepareDE <- function(de.raw, de.meta) {
    if (is.null(de.raw)) {
        return(NULL)
    }
    if (!is(de.raw, "data.table")) {
        de.raw <- as.data.table(
            as.data.frame(de.raw),
            keep.rownames = !is.numeric(attr(de.raw,
                                             "row.names")))
    }
    
    de <- copy(de.raw)
    
    for (columnName in names(de.meta$columns)) {
        prepareDEColumn(de, de.raw,
                        columnName,
                        de.meta$columns[[columnName]])
    }
    de[]
}

prepareDEColumn <- function(de, de.raw, columnName, from) {
    if (is.character(from)) {
        if (from == columnName) {
            return(de)
        }
        origToRename <- which(colnames(de) == columnName)
        if (length(origToRename) != 0) {
            setnames(de, origToRename, rep(paste0(columnName, ".orig"), length(origToRename)))        
        }
        setnames(de, old=from, new=columnName)    
    } else {
        de[, (columnName) := eval(from, envir = de.raw)]
    }
    de
}

getRanks <- function(geneDERaw, geneDEMeta, org.annos) {
    geneDE <- prepareDE(geneDERaw, geneDEMeta)
    org.anno <- org.annos[[geneDEMeta$organism]]
    
    if (geneDEMeta$idType != org.anno$baseId) {
        setkey(geneDE, ID)
        geneDE <- org.anno$mapFrom[[geneDEMeta$idType]][geneDE]
        setnames(geneDE, "gene", "ID")
        geneDE <- geneDE[!is.na(ID)]
    }
    
    if (!is.na(geneDEMeta$columns$baseMean)) {
        geneDE <- geneDE[order(baseMean, decreasing = T)]
        geneDE <- geneDE[!duplicated(ID)]
        geneDE <- head(geneDE, n=10000)
    } else {
        geneDE <- geneDE[order(abs(stat), decreasing = T)]
        geneDE <- geneDE[!duplicated(ID)]
    }
    
    ranks <- setNames(geneDE$stat, geneDE$ID)
    ranks.finite <- ranks[is.finite(ranks)]
    ranks[ranks > 0 & !is.finite(ranks)] <- max(ranks.finite)
    ranks[ranks < 0 & !is.finite(ranks)] <- min(ranks.finite)
    ranks <- sort(ranks, decreasing=TRUE)
    ranks
}
