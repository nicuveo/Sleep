# Tumblr API example

This file aims at showing how to use the Tumblr API, using the Web.Sleep
library. This file is a [literate Haskell](http://fixme.com) file, meaning it is
both rendered as documentation by Github and compilable by GHC. You can load it
in GHCI by running

```bash
$ stack ghci
λ :l src/Tutorial/Tumblr.hs
```


## Module and extensions

Nothing fancy here.

```haskell
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}

module Tutorial.Tumblr where

import           Data.List              as L
import           Control.Monad.Identity
import           Control.Exception.Safe
import           Control.Monad.Reader
import           Data.ByteString
import qualified Network.HTTP.Client    as N
```

## Sleep imports

There are two main entry points to the library:
  * `Web.Sleep.Tumblr` exports everything you'll need,
  * `Web.Sleep.Tumblr.Simple` exports additional helpers.

```haskell
import           Web.Sleep.Tumblr
import           Web.Sleep.Tumblr.Simple
```

## General design

With that out of the way, let's discuss how the Tumblr API is implemented.  Each
API function has a corresponding function: to get the posts of a blog, you would
use `getBlogPosts`, to post a new text entry, you would use `postNewBlogText`.

All those functions return a monadic `Query`. You can do two things with those:
  1. add optional parameters, using the `&=` operator (see examples below)
  2. send that query over the network using one of the three call functions,
     depending on what flavour of error handling you would prefer to use:
    * `call` returns a `m (Either Error Result)`
    * `callT` returns a `MonadThrow m => m Result`
    * `callE` returns a `MonadError Error m => m Result`

As such, most queries will be of this form:
`callT =<< getPostsByType AudioPost &= Limit 20`.

The monad in which those operations happen has several constraints; but before
showing how to implement our own, let's have a look at the _simple_ version of
the API.


## Simple usage

Those _simple_ functions are mostly wrappers around `runReaderT`, providing a
suitable monad stack in which to run our queries. There are two levels of
authentication for Tumblr API calls: either calling with simply an API key, or
by being authentified and signing requests with OAuth. Correspondingly, there
are two main `Simple` functions: `withAPIkey` and `withAuth`, which run in
`IO`. Some monad aliases are also defined:

```haskell
fetchBlogInfo :: APIKey -> IO Blog
fetchBlogInfo k = withAPIKey k theRequest
  where theRequest :: SimpleAPIKeyMonad IO Blog
        theRequest = callT =<< getBlogInfo "datblog.tumblr.com"

fetchBlogFollowers :: AuthCred -> IO BlogSummaryList
fetchBlogFollowers a = withAuth a theRequest
  where theRequest :: SimpleAuthCredMonad IO BlogSummaryList
        theRequest = callT =<< getBlogFollowers "datblog.tumblr.com"
```

The query functions are defined in such a way that trying to call a fuction that
requires authentication will fail to compile in the case where only an APIKey is
provided.

For more information on authentication, please see:
  * Web.Authenticate.OAuth
  * Web.Sleep.Tumblr.Auth
  * Web.Sleep.Tumblr.Simple


## Creating our own monad

For more interesting use cases, let's see how we could use our own monad to run
those queries. The most important requirement is for that monad to be an
instance of `MonadReader`. Let's first define our context, that will contain
everything we need.

### Context

```haskell
data Context = Context { apiKey  :: ByteString
                       , auth    :: AuthCred
                       , manager :: N.Manager
                       , blog    :: String
                       }
```

The manager is only required when running in `IO`. A similar context but without
the manager could be used for test purposes. There are several typeclasses of
which we need to make our Context an instance, mostly to retrieve those fields.

To start with, our context has an http manager:

```haskell
instance N.HasHttpManager Context where
  getHttpManager = manager
```

It also provides an API key:

```haskell
instance HasAPIKey Context where
  getAPIKey = APIKey . apiKey
```

For authentication, two instances. `MayHaveAuthCred` has a default
implementation that makes use of the `HasAuthCred` instance.

`MayHaveAuthCred` has only one function,
`maybeGetAuthCred :: a -> Maybe AuthCred`, which is used in all functions that
do not necessarily require authentication. It has a default overlappable
instance for all types a, which simply returns `Nothing`. But here, we are
authentified, and we can return an AuthCred in both cases.

```haskell
instance MayHaveAuthCred Context
instance HasAuthCred Context where
  getAuthCred = auth
```

Finally, this one is for convenience. All blog query functions have two
variants: one that expects the blog name as an argument, one that gets the blog
from the current context: `getBlogPosts` versus `getPosts`. The `Simple` API
also defines a wrapper around `withReaderT` that allows one to locally add a
blog name to a given context.

```haskell
instance HasBlogId Context where
  getBlogId = BlogId . blog
```


```haskell
type BaseTumblrMonad = ReaderT Context
newtype MyTumblrMonad m a = MyTumblrMonad {
  run :: BaseTumblrMonad m a
  } deriving (Functor,
              Applicative,
              Monad,
              MonadTrans,
              MonadThrow,
              MonadReader Context,
              MonadIO,
              MonadSign)
```



```haskell
instance HasNetwork Context m => HasNetwork Context (MyTumblrMonad m)
instance HasNetwork Context Identity where send = error "NOT IMPLEMENTED LOL"
```


```haskell
createTextPost :: String -> MyTumblrMonad IO ()
createTextPost content = callT =<< postNewText content &= Title "An update!"

hasDrafts :: (HasNetwork Context m, MonadSign m, MonadThrow m) => MyTumblrMonad m Bool
hasDrafts = do
  (PostList drafts) <- callT =<< getDraftPosts
  return $ not $ L.null drafts

getLastTenTextPosts :: MonadTumblrCall Context m => MyTumblrMonad m (Either Error PostList)
getLastTenTextPosts = call =<< getPostsByType TextType &= Limit 10
```
