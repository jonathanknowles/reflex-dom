{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, GeneralizedNewtypeDeriving, TypeFamilies, UndecidableInstances, RecursiveDo, ScopedTypeVariables, DataKinds, TypeOperators, PolyKinds #-}
module Reflex.Dom.PostBuild.Class where

import Reflex
import Reflex.Host.Class
import Reflex.Dom.Builder.Class
import Reflex.Dom.PerformEvent.Class
import Foreign.JavaScript.TH

import Control.Lens hiding (element)
import Control.Monad.Reader
import Control.Monad.Trans.Control
import Control.Monad.Ref
import Control.Monad.Exception

class (Reflex t, Monad m) => PostBuild t m where
  getPostBuild :: m (Event t ())

newtype PostBuildT t m a = PostBuildT { unPostBuildT :: ReaderT (Event t ()) m a } deriving (Functor, Applicative, Monad, MonadFix, MonadIO, MonadTrans, MonadException, MonadAsyncException)

instance MonadTransControl (PostBuildT t) where
  type StT (PostBuildT t) a = StT (ReaderT (Event t ())) a
  {-# INLINABLE liftWith #-}
  liftWith = defaultLiftWith PostBuildT unPostBuildT
  {-# INLINABLE restoreT #-}
  restoreT = defaultRestoreT PostBuildT

instance (Reflex t, Monad m) => PostBuild t (PostBuildT t m) where
  {-# INLINABLE getPostBuild #-}
  getPostBuild = PostBuildT ask

instance Deletable t m => Deletable t (PostBuildT t m) where
  {-# INLINABLE deletable #-}
  deletable d = liftThrough $ deletable d

{-# INLINABLE liftPostBuildTElementConfig #-}
liftPostBuildTElementConfig :: ElementConfig er t (PostBuildT t m) -> ElementConfig er t m
liftPostBuildTElementConfig cfg = cfg
  { _elementConfig_eventFilters = _elementConfig_eventFilters cfg
  , _elementConfig_eventHandler = _elementConfig_eventHandler cfg -- This requires PolyKinds, and will fail to unify types otherwise
  }

instance (DomBuilder t m, PerformEvent t m, MonadFix m, MonadHold t m) => DomBuilder t (PostBuildT t m) where
  type DomBuilderSpace (PostBuildT t m) = DomBuilderSpace m
  {-# INLINABLE textNode #-}
  textNode = lift . textNode
  {-# INLINABLE element #-}
  element t cfg child = liftWith $ \run -> element t (liftPostBuildTElementConfig cfg) $ run child
  {-# INLINABLE fragment #-}
  fragment cfg child = liftWith $ \run -> do
    rec (delayedDelete, childPostBuild) <- deletable delayedDelete $ do
          delayedDeleteInner <- performEvent $ return () <$ cfg ^. deleteSelf
          childPostBuildInner <- performEvent $ return () <$ _fragment_insertedAbove f
          return (delayedDeleteInner, childPostBuildInner)
        let cfg' = cfg
              { _fragmentConfig_insertAbove = fmap (\a -> runPostBuildT a =<< headE childPostBuild) $ _fragmentConfig_insertAbove cfg
              }
        (f, result) <- fragment cfg' $ run child
    return (f, result)
  {-# INLINABLE placeholder #-}
  placeholder cfg = lift $ do
    rec (delayedDelete, childPostBuild) <- deletable delayedDelete $ do
          delayedDeleteInner <- performEvent $ return () <$ cfg ^. deleteSelf
          childPostBuildInner <- performEvent $ return () <$ _placeholder_insertedAbove p
          return (delayedDeleteInner, childPostBuildInner)
        p <- placeholder $ cfg
          { _placeholderConfig_insertAbove = fmap (\a -> runPostBuildT a =<< headE childPostBuild) $ _placeholderConfig_insertAbove cfg
          }
    return p
  {-# INLINABLE inputElement #-}
  inputElement cfg = lift $ inputElement $ cfg & inputElementConfig_elementConfig %~ liftPostBuildTElementConfig
  {-# INLINABLE textAreaElement #-}
  textAreaElement cfg = lift $ textAreaElement $ cfg & textAreaElementConfig_elementConfig %~ liftPostBuildTElementConfig

instance MonadSample t m => MonadSample t (PostBuildT t m) where
  {-# INLINABLE sample #-}
  sample = lift . sample

instance MonadHold t m => MonadHold t (PostBuildT t m) where
  {-# INLINABLE hold #-}
  hold v0 = lift . hold v0
  {-# INLINABLE holdDyn #-}
  holdDyn v0 = lift . holdDyn v0
  {-# INLINABLE holdIncremental #-}
  holdIncremental v0 = lift . holdIncremental v0

instance PerformEvent t m => PerformEvent t (PostBuildT t m) where
  type Performable (PostBuildT t m) = PostBuildT t (Performable m)
  {-# INLINABLE performEvent_ #-}
  performEvent_ e = liftWith $ \run -> performEvent_ $ fmap run e
  {-# INLINABLE performEvent #-}
  performEvent e = liftWith $ \run -> performEvent $ fmap run e

instance (ReflexHost t, MonadReflexCreateTrigger t m) => MonadReflexCreateTrigger t (PostBuildT t m) where
  {-# INLINABLE newEventWithTrigger #-}
  newEventWithTrigger = PostBuildT . lift . newEventWithTrigger
  {-# INLINABLE newFanEventWithTrigger #-}
  newFanEventWithTrigger f = PostBuildT $ lift $ newFanEventWithTrigger f

instance TriggerEvent t m => TriggerEvent t (PostBuildT t m) where
  {-# INLINABLE newTriggerEvent #-}
  newTriggerEvent = lift newTriggerEvent
  {-# INLINABLE newTriggerEventWithOnComplete #-}
  newTriggerEventWithOnComplete = lift newTriggerEventWithOnComplete
  newEventWithLazyTriggerWithOnComplete = lift . newEventWithLazyTriggerWithOnComplete

instance MonadRef m => MonadRef (PostBuildT t m) where
  type Ref (PostBuildT t m) = Ref m
  {-# INLINABLE newRef #-}
  newRef = lift . newRef
  {-# INLINABLE readRef #-}
  readRef = lift . readRef
  {-# INLINABLE writeRef #-}
  writeRef r = lift . writeRef r

instance MonadAtomicRef m => MonadAtomicRef (PostBuildT t m) where
  {-# INLINABLE atomicModifyRef #-}
  atomicModifyRef r = lift . atomicModifyRef r

instance (HasJS x m, ReflexHost t) => HasJS x (PostBuildT t m) where
  type JSM (PostBuildT t m) = JSM m
  liftJS = lift . liftJS

instance HasWebView m => HasWebView (PostBuildT t m) where
  type WebViewPhantom (PostBuildT t m) = WebViewPhantom m
  askWebView = lift askWebView

{-# INLINABLE runPostBuildT #-}
runPostBuildT :: PostBuildT t m a -> Event t () -> m a
runPostBuildT (PostBuildT a) postBuild = runReaderT a postBuild

instance PostBuild t m => PostBuild t (ReaderT r m) where
  getPostBuild = lift getPostBuild
