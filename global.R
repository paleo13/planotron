### default options
options(shiny.error=traceback, stringsAsFactors=FALSE)

### load dependencies
library(rgdal)
library(leaflet)
library(RColorBrewer)
library(shinyBS)
library(mailR)
library(taRifx.geo)
library(Hmisc)
library(fortunes)
library(rgeos)

### load classes
source("classes.R")
source("leaflet.R")

### define global variables
# load data and set program vars
program_version="0.0.0"
load("data/data.RDATA")

# server settings
emailDF=try(read.table("private/mandrill_emailaccount.csv", sep=",", header=TRUE, as.is=TRUE))
shinyurl="https://paleo13.shinyapps.io/mapotron/"
emailWhiteList=read.table("private/emailwhitelist.csv", sep=",", header=TRUE, as.is=TRUE)[,1,drop=TRUE]
emailBlockList=read.table("private/emailblocklist.csv", sep=",", header=TRUE, as.is=TRUE)[,1,drop=TRUE]
fileExpiry=7


# colors
rwPals=c("Set1", "Dark2", "Accent")
rPals=c("Pastel1", "Pastel2", "Set2", "Set3")
rwCols=unlist(Map(brewer.pal, brewer.pal.info[match(rwPals, rownames(brewer.pal.info)),1], rwPals))
rCols=unlist(Map(brewer.pal, brewer.pal.info[match(rPals, rownames(brewer.pal.info)),1], rPals))
defaultCol='#1a16ff'

# default feature options
defaultStyles=list(
	rw=list(fillOpacity=0.7,opacity=1),
	r=list(fillOpacity=0.6,opacity=0.9)
)

### define functions
# misc functions
parseOpts=function(x) {
	return(unlist(x, recursive=FALSE))
}

featureColor=function(x) {
	return(featureCol[as.numeric(x) %% length(featureCol)])
}

baseColor=function(x) {
	return(baseCol[as.numeric(x) %% length(baseCol)])
}

sanitise=function(x) {
	x=deparse(x)
	chars=c("\\", "/", "'", '"', "<-", "=", "<<-")
	for (i in chars)
		x=gsub(i, "", x, fixed=TRUE)
	return(x)
}

generateUserId=function(x) {
	userId=paste0("user_",sample(1e+10,1))
	while(file.exists(file.path(x,userId))) {
		userId=paste0("user_",sample(1e+10,1))
	}
	return(userId)
}

# file management functions
saveSpatialData=function(features, expDir, info) {
	# generate nested list of objects
	tempLST=list(POINT=list(), LINESTRING=list(), POLYGON=list())
	for (i in seq_along(features))
		tempLST[[class(features[[i]])]][[length(tempLST[[class(features[[i]])]])+1]] = features[[i]]$to.sp()
	
	# save spatial objects
	for (i in seq_along(tempLST)) {
		if (length(tempLST[[i]])>0) {
			currSp=do.call(rbind, tempLST[[i]])
			for (j in seq_along(info))
				currSp@data[[names(info)[j]]]=info[[j]]
			currSp@data$created	= as.character(format(Sys.time(), tz="Australia/Brisbane"))
			writeOGR(
				currSp,
				expDir,
				names(tempLST)[i],
				overwrite=TRUE,
				driver="ESRI Shapefile"
			)
		}
	}
}

# json functions
list2json=function(prefix,lst) {
	if (length(lst)==0) {
		return("")
	} else {
		return(paste0(prefix,"{",paste(unlist(Map(function(x,y) {
			if (is.numeric(y)) {
				return(paste0('"', x, '":', y))
			} else {
				return(paste0('"', x, '":"', y, '"'))
			}
		}, names(lst), unlist(lst, use.names=FALSE)), use.names=FALSE), collapse=","),"}"))
	}
}

to_list=function(x) {
	lapply(seq_len(nrow(x)), function(i) x[i,])
}

to.geojson.from.SpatialPoints=function(x, cols, notes, style) {
	list(
		type="FeatureCollection",
		features=lapply(seq_len(nrow(x@coords)), function(l) {
			list(
				type="Feature",
				properties=list(note=notes[l], color=cols[l], fillColor=cols[l], opacity=style$opacity, fillOpacity=style$fillOpacity),
				geometry=list(
					type = "Point",
					coordinates=list(c(x@coords[l,]))
				)
			)
		})
	)
}


to.geojson.from.SpatialLines=function(x, cols, notes, style) {
	list(
		type="FeatureCollection",
		features=lapply(seq_along(x@lines), function(l) {
			list(
				type="Feature",
				properties=list(note=notes[l], color=cols[l], fillColor=cols[l], opacity=style$opacity, fillOpacity=style$fillOpacity),
				geometry=list(
					type = "MultiLineString",
					coordinates=list(lapply(x@lines[[l]]@Lines, function(m) {to_list(m@coords)}))
				)
			)
		})
	)
}

to.geojson.from.SpatialPolygons=function(x, cols, notes, style) {
	list(
		type="FeatureCollection",
		features=lapply(seq_along(x@polygons), function(l) {
			list(
				type="Feature",
				properties=list(note=notes[l], color=cols[l], fillColor=cols[l], opacity=style$opacity, fillOpacity=style$fillOpacity),
				geometry=list(
					type = "MultiPolygon",
					coordinates=list(lapply(x@polygons[[l]]@Polygons, function(m) {to_list(m@coords)}))
				)
			)
		})
	)
}

to.SpatialPoints.from.geojson=function(jsonlst, crs=CRS("+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs ")) {
	if (jsonlst$type=="Point") {
		coords=matrix(jsonlst$coordinates, ncol=2)
	}
	return(
		SpatialPoints(
			coords,
			proj4string=crs
		)
	)
}

to.SpatialLines.from.geojson=function(jsonlst, id, crs=CRS("+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs ")) {
	mainLST=list()
	if (jsonlst$type=="MultiLineString") {		
		for (i in seq_along(jsonlst$coordinates)) {
			currLST=list()
			for (j in seq_along(jsonlst$coordinates[[i]])) {
				currLST[[j]]=Line(do.call(rbind,jsonlst$coordinates[[i]][[j]]))
			}
			mainLST[[i]]=Lines(currLST, ID=paste0(.id, "_", i))
		}
	} else if (jsonlst$type=="LineString") {
		mainLST[[1]]=Lines(list(Line(do.call(rbind,jsonlst$coordinates))), ID=paste0(id, '_', 1))
	}
	return(
		SpatialLines(
				mainLST,
				crs
		)
	)
}

to.SpatialPolygons.from.geojson=function(jsonlst, id, crs=CRS("+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs ")) {
	mainLST=list()
	if (jsonlst$type=="MultiPolygon") {		
		for (i in seq_along(jsonlst$coordinates)) {
			currLST=list()
			for (j in seq_along(jsonlst$coordinates[[i]])) {
				currLST[[j]]=Polygon(do.call(rbind,jsonlst$coordinates[[i]][[j]]))
			}
			mainLST[[i]]=Polygons(currLST, ID=paste0(.id, "_", i))
		}
	} else if (jsonlst$type=="Polygon") {
		for (i in seq_along(jsonlst$coordinates)) {
			mainLST[[i]]=Polygons(list(Polygon(do.call(rbind,jsonlst$coordinates[[i]]))), ID=paste0(id, '_', i))
		}
	}
	return(
		SpatialPolygons(
				mainLST,
				proj4string=crs
		)
	)
}

to.SpatialPolygons.from.circle=function(jsonlst, id, radii, crs=CRS('+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs ')) {
	x=spTransform(gBuffer(spTransform(to.SpatialPoints.from.geojson(jsonlst, crs=crs), CRSobj=CRS('+proj=merc +a=6378137 +b=6378137 +lat_ts=0.0 +lon_0=0.0 +x_0=0.0 +y_0=0 +k=1.0 +units=m +nadgrids=@null +wktext  +no_defs')), width=radii, byid=TRUE),CRSobj=crs)
	return(spChFIDs(x,paste0(id, '_', seq_along(x@polygons))))
}

# sp functions
IDs.SpatialLinesDataFrame=function (x, ...) {
    vapply(slot(x, "lines"), function(x) slot(x, "ID"), "")
}

rbind.SpatialLinesDataFrame=function (..., fix.duplicated.IDs = TRUE) {
    dots <- as.list(substitute(list(...)))[-1L]
    dots_names <- as.character(dots)
    dots <- lapply(dots, eval)
    names(dots) <- NULL
    IDs_list <- lapply(dots, IDs)
    dups.sel <- duplicated(unlist(IDs_list))
    if (any(dups.sel)) {
        if (fix.duplicated.IDs) {
            dups <- unique(unlist(IDs_list)[dups.sel])
            fixIDs <- function(x, prefix, badIDs) {
                sel <- IDs(x) %in% badIDs
                IDs(x)[sel] <- paste(prefix, IDs(x)[sel], sep = ".")
                x
            }
            dots <- mapply(FUN = fixIDs, dots, dots_names, MoreArgs = list(badIDs = dups))
        }
        else {
            stop("There are duplicated IDs, and fix.duplicated.IDs is not TRUE.")
        }
    }
    else {
        broken_IDs <- vapply(dots, function(x) all(IDs(x) != rownames(x@data)), FALSE)
        if (any(broken_IDs)) {
            for (i in which(broken_IDs)) {
                rownames(dots[[i]]@data) <- IDs(dots[[i]])
            }
        }
    }
    pl = do.call("rbind", lapply(dots, function(x) as(x, "SpatialLines")))
    df = do.call("rbind", lapply(dots, function(x) x@data))
    sp::SpatialLinesDataFrame(pl, df)
}



